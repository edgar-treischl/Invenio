#!/usr/bin/env bash
# deploy.sh — Bootstrap InvenioRDM PoC on a fresh Ubuntu 22.04 VM.
#
# Run as a non-root user with sudo access:
#   git clone <repo> ~/invenio-repo && cd ~/invenio-repo
#   bash deploy.sh
#
# What this does:
#   1. Installs system packages, Python 3.9, Node.js 18
#   2. Installs and starts infrastructure services
#   3. Installs and starts MinIO automatically
#   4. Copies repo files into the expected home-directory layout
#   5. Installs Python dependencies into a virtualenv
#   6. Runs setup.sh to initialise the database, search, storage, and frontend
#   7. Installs and enables the nginx vhost and supervisord config
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
USER_HOME="$HOME"
INVENIO_RDM="$USER_HOME/invenio-rdm"
INVENIO_VENV="$USER_HOME/invenio-venv"
INVENIO_INSTANCE="$USER_HOME/invenio-instance"
MINIO_DATA="$USER_HOME/minio/data"
SUPERVISOR_CONF="$USER_HOME/invenio-supervisor.conf"

# MinIO credentials
MINIO_USER="minio"
MINIO_PASS="minio123456"
MINIO_ENDPOINT="http://127.0.0.1:9000"

log() { echo -e "\n\033[1;34m[deploy]\033[0m $*"; }

# ── 1. System packages ────────────────────────────────────────────────────────
log "Installing system packages …"
sudo apt-get update -qq
sudo apt-get install -y software-properties-common
if ! grep -Rq "deadsnakes/ppa" /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null; then
    log "Adding deadsnakes PPA for Python 3.9 …"
    sudo add-apt-repository -y ppa:deadsnakes/ppa
fi
sudo apt-get update -qq
sudo apt-get install -y \
    python3.9 python3.9-venv python3.9-dev python3-pip \
    gcc g++ git curl netcat-openbsd \
    libpq-dev \
    libcairo2 libpango-1.0-0 libpangocairo-1.0-0 libffi-dev \
    nginx supervisor

# Node.js 18
if ! node --version 2>/dev/null | grep -q "^v18"; then
    log "Installing Node.js 18 …"
    curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
    sudo apt-get install -y nodejs
fi
sudo npm install -g --quiet less clean-css-cli

# ── 2. Infrastructure services ────────────────────────────────────────────────
log "Installing PostgreSQL 14 …"
sudo apt-get install -y postgresql
sudo systemctl enable --now postgresql
sudo -u postgres psql -tc "SELECT 1 FROM pg_roles WHERE rolname='invenio'" \
    | grep -q 1 || sudo -u postgres psql <<SQL
CREATE USER invenio WITH PASSWORD 'invenio';
CREATE DATABASE invenio OWNER invenio;
SQL

log "Installing Redis 7 …"
sudo apt-get install -y redis-server
sudo systemctl enable --now redis-server

log "Installing RabbitMQ 3 …"
sudo apt-get install -y rabbitmq-server
sudo systemctl enable --now rabbitmq-server

# ── 3. OpenSearch 2.19.4 ─────────────────────────────────────────────────────
log "Installing OpenSearch 2.19.4 …"
if dpkg -l | grep -q opensearch; then
    echo "Removing previous OpenSearch installation..."
    sudo apt-get purge -y opensearch || true
fi
sudo rm -rf /etc/opensearch /var/lib/opensearch

if [ ! -f /etc/apt/sources.list.d/opensearch.list ]; then
    log "Adding OpenSearch repository..."
    curl -fsSL https://artifacts.opensearch.org/publickeys/opensearch.pgp \
        | sudo gpg --dearmor -o /usr/share/keyrings/opensearch.gpg
    echo "deb [signed-by=/usr/share/keyrings/opensearch.gpg] \
https://artifacts.opensearch.org/releases/bundle/opensearch/2.x/apt stable main" \
        | sudo tee /etc/apt/sources.list.d/opensearch.list
    sudo apt-get update -qq
fi

echo "Setting vm.max_map_count..."
sudo sysctl -w vm.max_map_count=262144
grep -q "vm.max_map_count" /etc/sysctl.conf || \
    echo "vm.max_map_count=262144" | sudo tee -a /etc/sysctl.conf

DEMO_INSTALLER="/usr/share/opensearch/plugins/opensearch-security/tools/install_demo_configuration.sh"
sudo mkdir -p "$(dirname "$DEMO_INSTALLER")"
sudo bash -c "echo -e '#!/bin/bash\nexit 0' > $DEMO_INSTALLER"
sudo chmod +x "$DEMO_INSTALLER"

OPENSEARCH_ADMIN_PASSWORD='S#cureP@ssw0rd2026!'
sudo DEBIAN_FRONTEND=noninteractive \
    OPENSEARCH_INITIAL_ADMIN_PASSWORD="$OPENSEARCH_ADMIN_PASSWORD" \
    DISABLE_INSTALL_DEMO_CONFIG=true \
    apt-get install -y opensearch
sudo DEBIAN_FRONTEND=noninteractive dpkg --configure -a

CONFIG_FILE="/etc/opensearch/opensearch.yml"
sudo mkdir -p "$(dirname "$CONFIG_FILE")"
sudo touch "$CONFIG_FILE"
grep -q "plugins.security.disabled" "$CONFIG_FILE" 2>/dev/null || \
    echo "plugins.security.disabled: true" | sudo tee -a "$CONFIG_FILE"

sudo systemctl enable --now opensearch
echo "✅ OpenSearch 2.19.4 installation complete!"
echo "Admin password: $OPENSEARCH_ADMIN_PASSWORD"

# ── 4. MinIO ─────────────────────────────────────────────────────────────────
log "Installing and starting MinIO …"
# Install MinIO binary if missing
if ! command -v minio >/dev/null 2>&1; then
    curl -O https://dl.min.io/server/minio/release/linux-amd64/minio
    chmod +x minio
    sudo mv minio /usr/local/bin/
fi

mkdir -p "$MINIO_DATA"
export MINIO_ROOT_USER="$MINIO_USER"
export MINIO_ROOT_PASSWORD="$MINIO_PASS"

nohup minio server "$MINIO_DATA" --console-address ":9001" > "$HOME/minio.log" 2>&1 &
sleep 5

export AWS_ACCESS_KEY_ID="$MINIO_USER"
export AWS_SECRET_ACCESS_KEY="$MINIO_PASS"

if ! command -v mc >/dev/null 2>&1; then
    curl -O https://dl.min.io/client/mc/release/linux-amd64/mc
    chmod +x mc
    sudo mv mc /usr/local/bin/
fi

mc alias set localminio "$MINIO_ENDPOINT" "$MINIO_USER" "$MINIO_PASS"
until mc ls localminio >/dev/null 2>&1; do
    log "Waiting for MinIO to accept credentials …"
    sleep 2
done
log "MinIO is ready."

# ── 5. Copy repo files ────────────────────────────────────────────────────────
log "Copying project files to $INVENIO_RDM …"
rsync -a --delete "$REPO_DIR/invenio-rdm/" "$INVENIO_RDM/"

log "Copying instance config to $INVENIO_INSTANCE …"
mkdir -p "$INVENIO_INSTANCE"
rsync -a "$REPO_DIR/invenio-instance/" "$INVENIO_INSTANCE/"

CURRENT_USER="$(whoami)"
sed -i "s/YOUR_USER/$CURRENT_USER/g" "$INVENIO_INSTANCE/uwsgi_ui.ini"
sed -i "s/YOUR_USER/$CURRENT_USER/g" "$INVENIO_INSTANCE/uwsgi_rest.ini"

log "Copying supervisor config …"
sed "s/YOUR_USER/$CURRENT_USER/g" "$REPO_DIR/invenio-supervisor.conf" > "$SUPERVISOR_CONF"

log "Installing nginx vhost …"
sed "s/YOUR_USER/$CURRENT_USER/g" "$REPO_DIR/nginx/invenio.conf" \
    | sudo tee /etc/nginx/sites-available/invenio >/dev/null
sudo ln -sf /etc/nginx/sites-available/invenio /etc/nginx/sites-enabled/invenio
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t && sudo systemctl reload nginx

# ── 6. Python virtualenv ──────────────────────────────────────────────────────
log "Creating virtualenv at $INVENIO_VENV …"
python3.9 -m venv "$INVENIO_VENV"
source "$INVENIO_VENV/bin/activate"
pip install --quiet --upgrade pip
pip install --quiet -r "$INVENIO_RDM/requirements.txt"

# ── 7. One-time setup ─────────────────────────────────────────────────────────
log "Running setup.sh …"
export INVENIO_INSTANCE_PATH="$INVENIO_INSTANCE"
bash "$INVENIO_RDM/scripts/setup.sh"

# ── 8. Start supervisor ───────────────────────────────────────────────────────
log "Starting application processes …"
supervisord -c "$SUPERVISOR_CONF"
sleep 5
supervisorctl -c "$SUPERVISOR_CONF" status

log "================================================"
log "Deployment complete!"
log "  UI  → http://localhost"
log "  API → http://localhost/api/records"
log "  Admin: admin@example.com / Admin1234!"
log ""
log "Run tests:  bash tests/01_services.sh"
log "            bash tests/02_app.sh"
log "================================================"