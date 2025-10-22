# 🚀 HNG13 Stage 1 — Automated Deployment using a Bash script


This project demonstrates automated deployment of a Dockerized Flask web application to a remote Linux server using a Bash script.  
It forms part of the **HNG13 DevOps Internship Stage 1 Task** — focused on automation, reliability, and cloud deployment.

---

## 🧩 Project Overview

The repository contains:

| File | Description |
|------|--------------|
| `app.py` | A simple Flask web server that returns a greeting message. |
| `requirements.txt` | Contains Python dependencies required by the app. |
| `Dockerfile` | Builds a lightweight Docker image for the Flask app. |
| `deploy.sh` | A Bash automation script that handles cloning, setup, Docker installation, deployment, and NGINX reverse proxy configuration. |
| `README.md` | Documentation explaining how the project works and how to use it. |

---

## 🐍 Flask Application Details

The Flask app (`app.py`) exposes one endpoint `/` that returns: Hello from HNG13 Stage 1 - Deployed via automated script!

### ✅ Run Locally (WSL/Linux)
```bash
# 1. Create a virtual environment
python3 -m venv venv
source venv/bin/activate

# 2. Install dependencies
pip install -r requirements.txt

# 3. Run the app
python app.py  
Then visit http://localhost:5000 in your browser to confirm it’s running.  
```  

## 🐳 Docker setup  
After writing the dockerfile, which contains a python:3.10-slim image, installs dependecies, and exposes a port, you build and run locally:  
```bash  
docker build -t hng-stage1-app .
docker run -d -p 5000:5000 hng-stage1-app
```  

## ⚙ Automated Deployment Script (script.sh)  
The deploy.sh script automates:

- Collecting inputs (Git repo, PAT, SSH credentials, app port)

- Cloning the repository (or pulling latest changes)

- Connecting to the remote server via SSH

- Installing Docker, Docker Compose, and NGINX (if missing)

- Transferring project files to the server

- Building and running the Docker container

- Configuring NGINX as a reverse proxy (port 80 → app port)

- Logging all actions for review

- Ensuring safe re-runs (idempotency and cleanup)  

## How To Use  
### Make the Script Executable  
```bash  
chmod +x deploy.sh
```  
### Run Deployment   
```bash  
./deploy.sh
```  

You’ll be prompted for:

GitHub Repository URL

Personal Access Token (PAT)

Branch name (optional, defaults to main)

Remote server username

Server IP address

SSH key path

Application port (e.g., 5000)  

### To safely remove previous deployments:
```bash
./deploy.sh --cleanup
```

