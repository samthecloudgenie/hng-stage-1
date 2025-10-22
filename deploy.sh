#!/bin/sh
# POSIX-style automated deployment script for HNG Stage 1
# Usage: ./deploy.sh
# NOTE: Test carefully on a non-production server first.

set -eu  # exit on error, treat unset vars as error

_TIMESTAMP() {
  date +"%Y%m%d_%H%M%S"
}

LOGFILE="deploy_$(date +%Y%m%d).log"
log() {
  msg="$1"
  printf "%s %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$msg" >> "$LOGFILE"
  printf "%s\n" "$msg"
}

err_exit() {
  log "ERROR: $1"
  exit 1
}

trap 'err_exit "Script interrupted or failed."' INT TERM HUP

# 1. Collect parameters
printf "Enter GitHub repo URL (https or ssh): "
read REPO_URL

printf "If using PAT for HTTPS cloning, enter it now (or press Enter to use normal git/ssh): "
read PAT
# If PAT provided, it'll be used in clone URL (note: PAT in command history is visible)

printf "Branch name (press Enter for main): "
read BRANCH
BRANCH=${BRANCH:-main}

printf "Remote SSH username (e.g. ubuntu): "
read SSH_USER

printf "Remote host (IP or DNS): "
read SSH_HOST

printf "Path to SSH key to use for remote access (full path, e.g. ~/hng.pem). If none, press Enter: "
read SSH_KEY
SSH_KEY_PATH=${SSH_KEY:-}

printf "Application internal container port (e.g. 5000): "
read APP_PORT

# Optional: remote target path
REMOTE_BASE_DIR="/opt/hng_stage1_app"

log "Starting deployment: repo=$REPO_URL branch=$BRANCH remote=${SSH_USER}@${SSH_HOST} app_port=${APP_PORT}"

# 2. Clone or update local repo copy in a temp folder
TMPDIR="/tmp/hng_stage1_src"
if [ -d "$TMPDIR" ]; then
  log "Updating existing local repo at $TMPDIR"
  cd "$TMPDIR" || err_exit "Cannot cd to $TMPDIR"
  # set remote
  if [ -n "$PAT" ]; then
    # embed PAT in URL for a one-time pull (warning: shows in process list/history)
    # If repo is https:
    case "$REPO_URL" in
      https://*)
        AUTH_URL="$(printf "%s" "$REPO_URL" | sed "s#https://#https://$PAT:@#")"
        git fetch --quiet origin || err_exit "git fetch failed"
        git checkout "$BRANCH" || git checkout -b "$BRANCH"
        git pull --quiet "$AUTH_URL" "$BRANCH" || err_exit "git pull failed"
        ;;
      *)
        git pull --quiet origin "$BRANCH" || err_exit "git pull failed"
        ;;
    esac
  else
    git fetch --quiet origin || err_exit "git fetch failed"
    # set to branch
    git checkout "$BRANCH" 2>/dev/null || git checkout -b "$BRANCH"
    git pull --quiet origin "$BRANCH" || err_exit "git pull failed"
  fi
else
  log "Cloning repository into $TMPDIR"
  rm -rf "$TMPDIR"
  mkdir -p "$TMPDIR"
  if [ -n "$PAT" ] && printf "%s" "$REPO_URL" | grep -q "^https://"; then
    AUTH_URL="$(printf "%s" "$REPO_URL" | sed "s#https://#https://$PAT:@#")"
    git clone --quiet --branch "$BRANCH" "$AUTH_URL" "$TMPDIR" || err_exit "git clone failed"
  else
    git clone --quiet --branch "$BRANCH" "$REPO_URL" "$TMPDIR" || err_exit "git clone failed"
  fi
fi

# Basic check for Dockerfile or docker-compose.yml
if [ ! -f "$TMPDIR/Dockerfile" ] && [ ! -f "$TMPDIR/docker-compose.yml" ] && [ ! -f "$TMPDIR/docker-compose.yaml" ]; then
  err_exit "Repository does not contain Dockerfile or docker-compose.yml"
fi

# 3. Prepare SSH options
SSH_OPTS=""
if [ -n "$SSH_KEY_PATH" ]; then
  SSH_OPTS="-i $SSH_KEY_PATH"
fi
SSH_TARGET="${SSH_USER}@${SSH_HOST}"

# 4. Remote connectivity check (ssh dry-run)
log "Checking SSH connectivity to $SSH_TARGET"
if ! ssh $SSH_OPTS -o BatchMode=yes -o ConnectTimeout=10 "$SSH_TARGET" "echo connected" >/dev/null 2>&1; then
  err_exit "SSH connection failed. Check key, user, and host."
fi
log "SSH check passed"

# 5. Prepare remote environment: create base dir
log "Creating remote directory $REMOTE_BASE_DIR"
ssh $SSH_OPTS "$SSH_TARGET" "sudo mkdir -p $REMOTE_BASE_DIR && sudo chown $(id -u):$(id -g) $REMOTE_BASE_DIR"

# 6. Transfer project using rsync (preserves only necessary files)
log "Syncing project files to remote host"
# Use rsync if available, fallback to scp
RSYNC_EXISTS=0
if command -v rsync >/dev/null 2>&1; then
  RSYNC_EXISTS=1
fi

if [ "$RSYNC_EXISTS" -eq 1 ]; then
  rsync -avz --delete --exclude '.git' -e "ssh $SSH_OPTS" "$TMPDIR"/ "$SSH_TARGET:$REMOTE_BASE_DIR/" >> "$LOGFILE" 2>&1 || err_exit "rsync failed"
else
  # tar over ssh fallback
  (cd "$TMPDIR" && tar -cz .) | ssh $SSH_OPTS "$SSH_TARGET" "sudo tar -xz -C $REMOTE_BASE_DIR" || err_exit "tar over ssh failed"
fi
log "Files transferred"

# 7. Remote install: Docker, docker-compose (simple install sequence)
REMOTE_CMDS='
set -eu
# Update and install prerequisites
if command -v docker >/dev/null 2>&1; then
  echo "docker-installed"
else
  # install docker using convenience script (works in most cases)
  curl -fsSL https://get.docker.com | sh
fi

if command -v docker-compose >/dev/null 2>&1; then
  echo "compose-installed"
else
  # Install docker-compose-plugin or docker-compose binary
  if docker compose version >/dev/null 2>&1; then
    echo "docker-compose-plugin"
  else
    # fallback to python pip-based docker-compose if needed
    apt-get update -y
    apt-get install -y python3-pip
    pip3 install docker-compose
  fi
fi

# Add user to docker group if not root
if [ "$(id -u)" -ne 0 ]; then
  sudo usermod -aG docker "$(whoami)" || true
fi

# Ensure nginx installed
if command -v nginx >/dev/null 2>&1; then
  echo "nginx-installed"
else
  apt-get update -y
  apt-get install -y nginx
fi

# Ensure base dir exists
mkdir -p '"$REMOTE_BASE_DIR"'
'

log "Running remote install and checks"
ssh $SSH_OPTS "$SSH_TARGET" "sudo sh -c '$REMOTE_CMDS'" >> "$LOGFILE" 2>&1 || err_exit "Remote preparation failed"
log "Remote prerequisites installed"

# 8. Build and run containers on remote
REMOTE_DEPLOY_CMDS='
set -eu
cd '"$REMOTE_BASE_DIR"'
# Stop and remove any old container named hng_stage1_app (if present)
if docker ps -a --format "{{.Names}}" | grep -q "^hng_stage1_app$"; then
  docker rm -f hng_stage1_app || true
fi

# If docker-compose is present and file exists, use it
if [ -f docker-compose.yml ] || [ -f docker-compose.yaml ]; then
  if command -v docker-compose >/dev/null 2>&1; then
    docker-compose down || true
    docker-compose up -d --build
  else
    docker compose down || true
    docker compose up -d --build
  fi
else
  # Build and run single Dockerfile
  docker build -t hng_stage1_image .
  docker run -d --name hng_stage1_app --restart unless-stopped -p 127.0.0.1:'"$APP_PORT"':'"$APP_PORT"' hng_stage1_image
fi
# allow a few seconds for app startup
sleep 3
# health check by curling the local container bind (loopback)
if command -v curl >/dev/null 2>&1; then
  curl -sS --connect-timeout 5 http://127.0.0.1:'"$APP_PORT"'/ >/dev/null 2>&1 || true
fi
'

log "Building and starting container on remote"
ssh $SSH_OPTS "$SSH_TARGET" "sudo sh -c '$REMOTE_DEPLOY_CMDS'" >> "$LOGFILE" 2>&1 || err_exit "Remote container build/run failed"
log "Container started on remote"

# 9. Configure nginx on remote (reverse proxy)
NGINX_CONF="/etc/nginx/sites-available/hng_stage1"
NGINX_LINK="/etc/nginx/sites-enabled/hng_stage1"

log "Configuring Nginx reverse proxy on remote"
create_nginx='
set -eu
cat > '"$NGINX_CONF"' <<EOF
server {
    listen 80;
    server_name '"$SSH_HOST"';

    location / {
        proxy_pass http://127.0.0.1:'"$APP_PORT"';
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
EOF

ln -sf '"$NGINX_CONF"' '"$NGINX_LINK"'
nginx -t
systemctl reload nginx
'
ssh $SSH_OPTS "$SSH_TARGET" "sudo sh -c '$create_nginx'" >> "$LOGFILE" 2>&1 || err_exit "Nginx configuration failed"
log "Nginx configured and reloaded"

# 10. Validation: check Docker, container, nginx, and try curl from remote
log "Running remote validation checks"

VALIDATE_CMDS='
set -eu
echo "Docker version:"
docker --version || true
echo "List containers:"
docker ps --filter "name=hng_stage1_app" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
# Test via curl from remote
if command -v curl >/dev/null 2>&1; then
  curl -sS --connect-timeout 5 http://127.0.0.1:'"$APP_PORT"'/ || true
  curl -sS --connect-timeout 5 http://127.0.0.1/ || true
fi
'

ssh $SSH_OPTS "$SSH_TARGET" "sudo sh -c '$VALIDATE_CMDS'" >> "$LOGFILE" 2>&1 || err_exit "Validation checks failed"

# 11. Final external check (from local machine)
log "Testing public accessibility (local HTTP check)"
if command -v curl >/dev/null 2>&1; then
  if curl -sS --connect-timeout 8 "http://$SSH_HOST/" >/dev/null 2>&1; then
    log "SUCCESS: http://$SSH_HOST/ is reachable"
  else
    log "WARNING: http://$SSH_HOST/ is not reachable from local machine. Check firewall/security groups."
  fi
else
  log "Skipping external curl test because curl is not available locally."
fi

log "Deployment finished successfully"
exit 0
