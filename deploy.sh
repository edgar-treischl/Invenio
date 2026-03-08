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
PUBLIC_HOST="${PUBLIC_HOST:-localhost}"

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
# Stop OpenSearch before wiping its data/config dirs to avoid broken node lock.
sudo systemctl stop opensearch 2>/dev/null || true
# Always purge so apt always runs a clean first-install (not an "upgrade"),
# avoiding the postinst's service-restart branch that fires on upgrades.
sudo apt-get purge -y opensearch 2>/dev/null || true
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

# Patch the postinst to create /var/run/opensearch before chowning it.
# The directory is normally managed by systemd's RuntimeDirectory, so it does
# not exist at the time the postinst runs — the stock script tries to chown a
# non-existent path and fails with "No such file or directory".
if [ -f /var/lib/dpkg/info/opensearch.postinst ]; then
    sudo sed -i 's|chown -R opensearch:opensearch \${pid_dir}|mkdir -p ${pid_dir} \&\& chown -R opensearch:opensearch ${pid_dir}|g' \
        /var/lib/dpkg/info/opensearch.postinst
fi

OPENSEARCH_ADMIN_PASSWORD='S#cureP@ssw0rd2026!'
sudo DEBIAN_FRONTEND=noninteractive \
    OPENSEARCH_INITIAL_ADMIN_PASSWORD="$OPENSEARCH_ADMIN_PASSWORD" \
    DISABLE_INSTALL_DEMO_CONFIG=true \
    apt-get install -y opensearch
# Run dpkg --configure only if dpkg reports unfinished packages; the
# postinst already starts opensearch on first install so we skip a redundant
# configure pass that would trigger another (failing) service restart.
sudo DEBIAN_FRONTEND=noninteractive dpkg --configure -a 2>/dev/null || true

# Write a clean opensearch.yml (not append) so we never get duplicate keys.
CONFIG_FILE="/etc/opensearch/opensearch.yml"
sudo bash -c "echo 'plugins.security.disabled: true' > $CONFIG_FILE"
sudo chown opensearch:opensearch "$CONFIG_FILE"
sudo chmod 640 "$CONFIG_FILE"

# Ensure the data and pid directories exist with the correct ownership.
# apt postinst creates these on first install but they may be absent on
# re-runs where the service was stopped before the directories were created.
sudo mkdir -p /var/lib/opensearch /var/run/opensearch
sudo chown opensearch:opensearch /var/lib/opensearch /var/run/opensearch

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

# Stop any existing MinIO process to avoid port conflicts on re-runs.
# (pkill is unavailable; locate via ps and kill by PID.)
ps aux | awk '/[/]usr[/]local[/]bin[/]minio/ && !/awk/ {print $2}' \
    | xargs -r -I{} sh -c 'kill {} 2>/dev/null; true'
sleep 2

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

log "Configuring allowed hosts and site URLs for $PUBLIC_HOST …"
INVENIO_INSTANCE="$INVENIO_INSTANCE" PUBLIC_HOST="$PUBLIC_HOST" python3 - <<'PY'
import os, pathlib, re
cfg_path = pathlib.Path(os.environ["INVENIO_INSTANCE"]) / "invenio.cfg"
host = os.environ["PUBLIC_HOST"]
text = cfg_path.read_text()
text = re.sub(
    r'APP_ALLOWED_HOSTS\s*=.*',
    f'APP_ALLOWED_HOSTS = ["localhost", "127.0.0.1", "0.0.0.0", "{host}"]',
    text,
)
text = re.sub(r'SITE_UI_URL\s*=.*',  f'SITE_UI_URL  = "http://{host}"', text)
text = re.sub(r'SITE_API_URL\s*=.*', f'SITE_API_URL = "http://{host}/api"', text)
cfg_path.write_text(text)
PY

log "Copying supervisor config …"
sed "s/YOUR_USER/$CURRENT_USER/g" "$REPO_DIR/invenio-supervisor.conf" > "$SUPERVISOR_CONF"

log "Installing nginx vhost …"
sed -e "s/YOUR_USER/$CURRENT_USER/g" -e "s/PUBLIC_HOST/$PUBLIC_HOST/g" \
    "$REPO_DIR/nginx/invenio.conf" \
    | sudo tee /etc/nginx/sites-available/invenio >/dev/null
sudo ln -sf /etc/nginx/sites-available/invenio /etc/nginx/sites-enabled/invenio
sudo rm -f /etc/nginx/sites-enabled/default
# nginx (www-data) must be able to traverse the home directory to serve /static.
chmod o+x "$USER_HOME"
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
# Shut down any previously running supervisord (and its managed processes)
# before starting a fresh instance. Without this, stale uwsgi workers holding
# ports 5000/5001 cause the new invenio-ui/invenio-api programs to FATAL.
if supervisorctl -c "$SUPERVISOR_CONF" shutdown 2>/dev/null; then
    sleep 5
fi
# Kill any orphaned uwsgi workers or minio not tracked by supervisor.
# (We avoid pkill which is not always available; use ps+awk+xargs instead.)
ps aux | awk '/uwsgi.*(uwsgi_rest|uwsgi_ui)/ && !/awk/ {print $2}' \
    | xargs -r -I{} sh -c 'kill {} 2>/dev/null; true'
ps aux | awk '/[/]usr[/]local[/]bin[/]minio/ && !/awk/ {print $2}' \
    | xargs -r -I{} sh -c 'kill {} 2>/dev/null; true'
sleep 2

# Ensure supervisor log files are owned by the current user so supervisord
# (which runs as this user) can write to them even on re-runs.
touch /tmp/minio.log /tmp/celery.log /tmp/invenio-api.log /tmp/invenio-ui.log
# (chown is only needed if root created them on a previous run)
sudo chown "$CURRENT_USER:$CURRENT_USER" \
    /tmp/minio.log /tmp/celery.log /tmp/invenio-api.log /tmp/invenio-ui.log 2>/dev/null || true

supervisord -c "$SUPERVISOR_CONF"
sleep 8
supervisorctl -c "$SUPERVISOR_CONF" status

log "================================================"
log "Deployment complete!"
log "  UI  → http://${PUBLIC_HOST}"
log "  API → http://${PUBLIC_HOST}/api/records"
log "  Admin: admin@example.com / Admin1234!"
log ""
log "Run tests:  bash tests/01_services.sh"
log "            bash tests/02_app.sh"
log "================================================"
