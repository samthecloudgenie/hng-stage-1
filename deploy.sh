#!/bin/sh

set -eu

_now() { date +"%Y%m%d_%H%M%S"; }
LOGFILE="deploy_$(_now).log"
log() { printf "%s %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOGFILE"; printf "%s\n" "$1"; }

err_exit() {
  log "ERROR: $1"
  printf "ERROR: %s\n" "$1" >&2
  exit "${2:-1}"
}

# parse optional flag
CLEANUP=0
if [ "${1:-}" = "--cleanup" ]; then
  CLEANUP=1
fi

# prompt helper that supports default
_prompt() {
  prompt="$1"
  default="$2"
  if [ -n "$default" ]; then
    printf "%s (%s): " "$prompt" "$default"
  else
    printf "%s: " "$prompt"
  fi
  read ans
  if [ -z "$ans" ]; then
    printf "%s\n" "${default:-}"
  else
    printf "%s\n" "$ans"
  fi
}

# collect minimal info needed for cleanup if asked
if [ "$CLEANUP" -eq 1 ]; then
  printf "Running cleanup mode. I need connection info.\n"
  REPO_URL=""
  printf "Remote server username (e.g. ubuntu): "
  read SSH_USER
  printf "Server IP or DNS: "
  read SSH_HOST
  printf "SSH key path (full path): "
  read SSH_KEY_IN
  SSH_KEY_PATH=$(eval echo "${SSH_KEY_IN}")
  log "Cleanup requested for ${SSH_USER}@${SSH_HOST} (key=${SSH_KEY_PATH})"
  SSH_OPTS="-i $SSH_KEY_PATH -o BatchMode=yes -o StrictHostKeyChecking=no"
  SSH_TARGET="${SSH_USER}@${SSH_HOST}"
  log "Starting remote cleanup..."
  ssh $SSH_OPTS "$SSH_TARGET" <<'REMOTE_CLEAN'
set -eu
echo "Stopping + removing container and image..."
sudo docker rm -f hng_stage1_app || true
sudo docker rmi -f hng_stage1_image || true
echo "Removing app dir..."
sudo rm -rf /opt/hng_stage1_app || true
echo "Removing nginx configs..."
sudo rm -f /etc/nginx/sites-enabled/hng_stage1 /etc/nginx/sites-available/hng_stage1 || true
echo "Testing and reloading nginx..."
sudo nginx -t || true
sudo systemctl reload nginx || true
echo "CLEANUP_DONE"
REMOTE_CLEAN
  log "Cleanup finished on remote host $SSH_HOST"
  printf "Cleanup finished. Check %s for logs.\n" "$LOGFILE"
  exit 0
fi

# ---------- Interactive deploy inputs ----------
printf "GitHub Repository URL (https or ssh): "
read REPO_URL

printf "Personal Access Token (PAT) (press Enter for none): "
read PAT

printf "Branch name (default: main): "
read BRANCH
BRANCH=${BRANCH:-main}

printf "Remote server username (e.g. ubuntu): "
read SSH_USER

printf "Server IP or DNS (public): "
read SSH_HOST

printf "SSH key path (full path, e.g. /home/samuel/HNG-1.pem): "
read SSH_KEY_IN
SSH_KEY_PATH=$(eval echo "${SSH_KEY_IN}")

printf "Application internal container port (e.g. 5000): "
read APP_PORT
APP_PORT=${APP_PORT:-5000}

REMOTE_BASE_DIR="/opt/hng_stage1_app"
log "Inputs: repo=$REPO_URL branch=$BRANCH remote=${SSH_USER}@${SSH_HOST} key=${SSH_KEY_PATH} port=$APP_PORT"

# basic local prechecks
if [ -n "$SSH_KEY_PATH" ] && [ ! -f "$SSH_KEY_PATH" ]; then
  err_exit "SSH key not found at $SSH_KEY_PATH"
fi

# clone/pull locally
TMPDIR="/tmp/hng_stage1_src"
if [ -d "$TMPDIR" ]; then
  log "Updating local repo at $TMPDIR"
  cd "$TMPDIR" || err_exit "cd $TMPDIR failed"
  if [ -n "$PAT" ] && printf "%s" "$REPO_URL" | grep -q "^https://"; then
    AUTH_URL="$(printf "%s" "$REPO_URL" | sed "s#https://#https://$PAT:@#")"
    git fetch --quiet origin || err_exit "git fetch failed"
    git checkout "$BRANCH" 2>/dev/null || git checkout -b "$BRANCH"
    git pull --quiet "$AUTH_URL" "$BRANCH" || err_exit "git pull failed"
  else
    git fetch --quiet origin || err_exit "git fetch failed"
    git checkout "$BRANCH" 2>/dev/null || git checkout -b "$BRANCH"
    git pull --quiet origin "$BRANCH" || err_exit "git pull failed"
  fi
else
  log "Cloning $REPO_URL into $TMPDIR"
  rm -rf "$TMPDIR" || true
  mkdir -p "$TMPDIR"
  if [ -n "$PAT" ] && printf "%s" "$REPO_URL" | grep -q "^https://"; then
    AUTH_URL="$(printf "%s" "$REPO_URL" | sed "s#https://#https://$PAT:@#")"
    git clone --quiet --branch "$BRANCH" "$AUTH_URL" "$TMPDIR" || err_exit "git clone failed"
  else
    git clone --quiet --branch "$BRANCH" "$REPO_URL" "$TMPDIR" || err_exit "git clone failed"
  fi
fi

# verify dockerfile or compose present
if [ ! -f "$TMPDIR/Dockerfile" ] && [ ! -f "$TMPDIR/docker-compose.yml" ] && [ ! -f "$TMPDIR/docker-compose.yaml" ]; then
  err_exit "Repository does not contain Dockerfile or docker-compose.yml"
fi
log "Local repo ready."

# SSH check
SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no"
if [ -n "$SSH_KEY_PATH" ]; then
  SSH_OPTS="-i $SSH_KEY_PATH $SSH_OPTS"
fi
SSH_TARGET="${SSH_USER}@${SSH_HOST}"

log "Checking SSH connectivity to $SSH_TARGET"
if ! ssh $SSH_OPTS "$SSH_TARGET" "echo connected" >/dev/null 2>&1; then
  err_exit "SSH connectivity failed. Check key, user, host, and that port 22 is open."
fi
log "SSH OK."

# create remote base dir
log "Creating remote base dir $REMOTE_BASE_DIR"
ssh $SSH_OPTS "$SSH_TARGET" "sudo mkdir -p $REMOTE_BASE_DIR && sudo chown \$(id -u):\$(id -g) $REMOTE_BASE_DIR" || err_exit "Failed to create remote dir"

# transfer files using rsync or tar fallback
log "Transferring files to remote"
if command -v rsync >/dev/null 2>&1; then
  rsync -avz --delete --exclude '.git' -e "ssh $SSH_OPTS" "$TMPDIR"/ "$SSH_TARGET:$REMOTE_BASE_DIR/" >> "$LOGFILE" 2>&1 || err_exit "rsync failed"
else
  (cd "$TMPDIR" && tar -cz .) | ssh $SSH_OPTS "$SSH_TARGET" "sudo tar -xz -C $REMOTE_BASE_DIR" >> "$LOGFILE" 2>&1 || err_exit "tar over ssh failed"
fi
log "Files transferred"

# Upload and run remote deploy script reliably
REMOTE_SCRIPT="/tmp/hng_deploy_remote_$(_now).sh"
cat > /tmp/hng_deploy_remote.sh <<'REMOTE_EOF'
#!/bin/sh
set -eu
export PATH=$PATH:/usr/sbin

REMOTE_BASE_DIR="@REMOTE_BASE_DIR@"
APP_PORT="@APP_PORT@"
SSH_HOST_PLACEHOLDER="@SSH_HOST@"

# install docker if missing
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
fi

# install docker-compose if missing (plugin or pip fallback)
if ! command -v docker-compose >/dev/null 2>&1; then
  if docker compose version >/dev/null 2>&1; then
    :
  else
    apt-get update -y
    apt-get install -y python3-pip
    pip3 install docker-compose
  fi
fi

# ensure nginx
if ! command -v nginx >/dev/null 2>&1; then
  apt-get update -y
  apt-get install -y nginx
fi

# add user to docker group (safe)
if [ "$(id -u)" -ne 0 ]; then
  sudo usermod -aG docker "$(whoami)" || true
fi

mkdir -p "$REMOTE_BASE_DIR"
chown $(id -u):$(id -g) "$REMOTE_BASE_DIR" || true
cd "$REMOTE_BASE_DIR"

# remove previous container if exists
if docker ps -a --format "{{.Names}}" | grep -q "^hng_stage1_app$"; then
  docker rm -f hng_stage1_app || true
fi

# build and run
if [ -f docker-compose.yml ] || [ -f docker-compose.yaml ]; then
  if command -v docker-compose >/dev/null 2>&1; then
    docker-compose down || true
    docker-compose up -d --build
  else
    docker compose down || true
    docker compose up -d --build
  fi
else
  docker build -t hng_stage1_image .
  docker run -d --name hng_stage1_app --restart unless-stopped -p 127.0.0.1:$APP_PORT:$APP_PORT hng_stage1_image
fi

sleep 4

# create nginx conf (use temp file then move)
NGINX_TMP="/tmp/hng_stage1_conf"
cat > "$NGINX_TMP" <<'NGCONF'
server {
    listen 80;
    server_name PLACEHOLDER_HOST;

    location / {
        proxy_pass http://127.0.0.1:PLACEHOLDER_PORT;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
NGCONF

# replace placeholders
sed -i "s|PLACEHOLDER_HOST|$SSH_HOST_PLACEHOLDER|g" "$NGINX_TMP"
sed -i "s|PLACEHOLDER_PORT|$APP_PORT|g" "$NGINX_TMP"

sudo mv "$NGINX_TMP" /etc/nginx/sites-available/hng_stage1
sudo ln -sf /etc/nginx/sites-available/hng_stage1 /etc/nginx/sites-enabled/hng_stage1

# fix server_names_hash_bucket_size
if ! grep -q 'server_names_hash_bucket_size' /etc/nginx/nginx.conf 2>/dev/null; then
  sudo sed -i '/http {/a \    server_names_hash_bucket_size 64;' /etc/nginx/nginx.conf || true
fi

# test and reload nginx (use full path)
if [ -x /usr/sbin/nginx ]; then
  /usr/sbin/nginx -t
else
  nginx -t
fi
sudo systemctl reload nginx || true

# validations
echo "REMOTE_VALIDATION: docker: $(docker --version 2>&1 || true)"
docker ps --filter "name=hng_stage1_app" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
if command -v curl >/dev/null 2>&1; then
  curl -sS --connect-timeout 5 http://127.0.0.1:$APP_PORT >/dev/null 2>&1 && echo "REMOTE_VALIDATION: app_ok" || echo "REMOTE_VALIDATION: app_not_ok"
  curl -sS --connect-timeout 5 http://127.0.0.1/ >/dev/null 2>&1 || true
fi

REMOTE_EOF

# substitute variables into remote script safely
sed "s|@REMOTE_BASE_DIR@|$REMOTE_BASE_DIR|g; s|@APP_PORT@|$APP_PORT|g; s|@SSH_HOST@|$SSH_HOST|g" /tmp/hng_deploy_remote.sh > /tmp/hng_deploy_remote_filled.sh
scp $SSH_OPTS /tmp/hng_deploy_remote_filled.sh "$SSH_TARGET:/tmp/hng_deploy_remote_filled.sh" >> "$LOGFILE" 2>&1 || err_exit "Failed to upload remote script"
ssh $SSH_OPTS "$SSH_TARGET" "chmod +x /tmp/hng_deploy_remote_filled.sh && sudo sh /tmp/hng_deploy_remote_filled.sh" >> "$LOGFILE" 2>&1 || err_exit "Remote deployment failed. See log $LOGFILE"

log "Remote deployment completed. Verifying public endpoint..."
if command -v curl >/dev/null 2>&1; then
  if curl -sS --connect-timeout 8 "http://$SSH_HOST/" >/dev/null 2>&1; then
    log "SUCCESS: http://$SSH_HOST/ reachable"
    printf "SUCCESS: http://%s/ is reachable\n" "$SSH_HOST"
  else
    log "WARNING: http://$SSH_HOST/ NOT reachable from this machine"
    printf "WARNING: http://%s/ NOT reachable from this machine. Check SG/firewalls and nginx logs.\n" "$SSH_HOST"
  fi
else
  log "Skipping external curl test (curl not installed locally)"
fi

log "Deployment finished. Log: $LOGFILE"
printf "Done. Check %s for full logs\n" "$LOGFILE"
exit 0
