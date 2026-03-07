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
#   3. Copies repo files into the expected home-directory layout
#   4. Installs Python dependencies into a virtualenv
#   5. Runs setup.sh to initialise the database, search, storage, and frontend
#   6. Installs and enables the nginx vhost and supervisord config
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
USER_HOME="$HOME"
INVENIO_RDM="$USER_HOME/invenio-rdm"
INVENIO_VENV="$USER_HOME/invenio-venv"
INVENIO_INSTANCE="$USER_HOME/invenio-instance"
MINIO_DATA="$USER_HOME/minio/data"
SUPERVISOR_CONF="$USER_HOME/invenio-supervisor.conf"

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
# Jammy ships PostgreSQL 14 as the default; install without version pin to avoid missing pkg errors.
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

log "Installing OpenSearch 2 …"
if ! systemctl is-active --quiet opensearch; then
    curl -fsSL https://artifacts.opensearch.org/publickeys/opensearch.pgp \
        | sudo gpg --dearmor -o /usr/share/keyrings/opensearch.gpg
    echo "deb [signed-by=/usr/share/keyrings/opensearch.gpg] \
https://artifacts.opensearch.org/releases/bundle/opensearch/2.x/apt stable main" \
        | sudo tee /etc/apt/sources.list.d/opensearch.list
    sudo apt-get update -qq
    # If a previous install failed in postinst, purge it to clear the half-configured state.
    if dpkg -s opensearch 2>/dev/null | grep -q "Status: install ok installed"; then
        :
    else
        sudo apt-get purge -y opensearch || true
    fi
    # Skip the demo security config to avoid failing post-install script.
    echo "DISABLE_INSTALL_DEMO_CONFIG=true" | sudo tee /etc/default/opensearch >/dev/null
    if ! sudo DISABLE_INSTALL_DEMO_CONFIG=true OPENSEARCH_INITIAL_ADMIN_PASSWORD=Admin1234! \
        DEBIAN_FRONTEND=noninteractive apt-get install -y opensearch; then
        # If configure failed, retry configuration with the env flags set.
        sudo DISABLE_INSTALL_DEMO_CONFIG=true OPENSEARCH_INITIAL_ADMIN_PASSWORD=Admin1234! \
            dpkg --configure -a
    fi
    grep -q "plugins.security.disabled" /etc/opensearch/opensearch.yml \
        || echo 'plugins.security.disabled: true' | sudo tee -a /etc/opensearch/opensearch.yml
    sudo systemctl enable --now opensearch
fi

log "Installing MinIO …"
if [ ! -f /usr/local/bin/minio ]; then
    sudo curl -Lo /usr/local/bin/minio \
        https://dl.min.io/server/minio/release/linux-amd64/minio
    sudo chmod +x /usr/local/bin/minio
fi
mkdir -p "$MINIO_DATA"

# ── 3. Copy repo files ────────────────────────────────────────────────────────
log "Copying project files to $INVENIO_RDM …"
rsync -a --delete "$REPO_DIR/invenio-rdm/" "$INVENIO_RDM/"

log "Copying instance config to $INVENIO_INSTANCE …"
mkdir -p "$INVENIO_INSTANCE"
rsync -a "$REPO_DIR/invenio-instance/" "$INVENIO_INSTANCE/"

# Patch YOUR_USER placeholder in uwsgi ini and nginx conf
CURRENT_USER="$(whoami)"
sed -i "s/YOUR_USER/$CURRENT_USER/g" "$INVENIO_INSTANCE/uwsgi_ui.ini"
sed -i "s/YOUR_USER/$CURRENT_USER/g" "$INVENIO_INSTANCE/uwsgi_rest.ini"

log "Copying supervisor config …"
sed "s/YOUR_USER/$CURRENT_USER/g" "$REPO_DIR/invenio-supervisor.conf" > "$SUPERVISOR_CONF"

log "Installing nginx vhost …"
sudo sed "s/YOUR_USER/$CURRENT_USER/g" "$REPO_DIR/nginx/invenio.conf" \
    > /etc/nginx/sites-available/invenio
sudo ln -sf /etc/nginx/sites-available/invenio /etc/nginx/sites-enabled/invenio
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t && sudo systemctl reload nginx

# ── 4. Python virtualenv ──────────────────────────────────────────────────────
log "Creating virtualenv at $INVENIO_VENV …"
python3.9 -m venv "$INVENIO_VENV"
# shellcheck disable=SC1090
source "$INVENIO_VENV/bin/activate"
pip install --quiet --upgrade pip
pip install --quiet -r "$INVENIO_RDM/requirements.txt"

# ── 5. One-time setup ─────────────────────────────────────────────────────────
log "Running setup.sh …"
export INVENIO_INSTANCE_PATH="$INVENIO_INSTANCE"
bash "$INVENIO_RDM/scripts/setup.sh"

# ── 6. Start supervisor ───────────────────────────────────────────────────────
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
