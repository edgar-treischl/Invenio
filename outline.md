# InvenioRDM PoC — Native Setup on Ubuntu 22.04

> **This document is self-contained.**  
> Everything needed to recreate the repository and run the full stack from
> scratch on a clean Ubuntu 22.04 VM is embedded below — every config file,
> every script, every dataset file.  No Docker is used for the application.
> Infrastructure services (PostgreSQL, Redis, OpenSearch, RabbitMQ, MinIO)
> run as native OS services, exactly as they would in a production VM deployment.

---

## Table of Contents

1. [Architecture](#1-architecture)
2. [System Prerequisites](#2-system-prerequisites)
3. [Infrastructure Services](#3-infrastructure-services)
4. [Project Layout — Create All Files](#4-project-layout--create-all-files)
5. [One-time Initialisation](#5-one-time-initialisation)
6. [Running the Application](#6-running-the-application)
7. [Ingest the Iris Dataset](#7-ingest-the-iris-dataset)
8. [API Preview](#8-api-preview)
9. [Quick Reference](#9-quick-reference)

---

## 1. Architecture

```
Browser
  └─▶ Nginx :80
        ├─▶ /static  → ~/invenio-instance/static/   (served directly)
        ├─▶ /api/*   → uWSGI :5001  (REST API, /api prefix stripped)
        └─▶ /*       → uWSGI :5000  (UI)

uWSGI :5000  ←→  invenio_app.factory.create_ui()
uWSGI :5001  ←→  invenio_app.factory.create_api()

Celery worker
  ├─▶ RabbitMQ :5672   (task queue / broker)
  └─▶ Redis    :6379/2 (result backend)

Both WSGI apps
  ├─▶ PostgreSQL  :5432  (metadata / relational store)
  ├─▶ OpenSearch  :9200  (full-text search index)
  ├─▶ Redis       :6379  (cache, sessions, rate limiter)
  └─▶ MinIO       :9000  (S3-compatible object storage for files)
```

| Service | Port | Role |
|---|---|---|
| Nginx | 80 | Reverse proxy |
| uWSGI UI | 5000 | InvenioRDM web interface |
| uWSGI API | 5001 | InvenioRDM REST API |
| Celery | — | Background task worker |
| PostgreSQL 14 | 5432 | Metadata database |
| OpenSearch 2 | 9200 | Search index |
| Redis 7 | 6379 | Cache / sessions / broker backend |
| RabbitMQ 3 | 5672 | Celery message broker |
| MinIO | 9000 | Object storage (S3-compatible) |
| MinIO console | 9001 | MinIO web UI |

---

## 2. System Prerequisites

Run all commands as a non-root user with `sudo` access.

```bash
sudo apt-get update && sudo apt-get install -y \
    python3.9 python3.9-venv python3.9-dev python3-pip \
    gcc g++ git curl netcat \
    libpq-dev \
    libcairo2 libpango-1.0-0 libpangocairo-1.0-0 libffi-dev \
    nginx supervisor
```

### Node.js 18

```bash
curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
sudo apt-get install -y nodejs
sudo npm install -g less clean-css-cli
```

Verify:

```bash
python3.9 --version   # Python 3.9.x
node --version        # v18.x.x
lessc --version       # lessc 4.x.x
```

---

## 3. Infrastructure Services

### 3.1 PostgreSQL 14

```bash
sudo apt-get install -y postgresql-14
sudo systemctl enable --now postgresql

sudo -u postgres psql <<SQL
CREATE USER invenio WITH PASSWORD 'invenio';
CREATE DATABASE invenio OWNER invenio;
SQL
```

Verify: `psql -U invenio -h localhost invenio -c '\l'`

### 3.2 Redis 7

```bash
sudo apt-get install -y redis-server
sudo systemctl enable --now redis-server
```

Verify: `redis-cli ping`  → `PONG`

### 3.3 OpenSearch 2

```bash
curl -fsSL https://artifacts.opensearch.org/publickeys/opensearch.pgp \
  | sudo gpg --dearmor -o /usr/share/keyrings/opensearch.gpg

echo "deb [signed-by=/usr/share/keyrings/opensearch.gpg] \
https://artifacts.opensearch.org/releases/bundle/opensearch/2.x/apt stable main" \
  | sudo tee /etc/apt/sources.list.d/opensearch.list

sudo apt-get update && sudo OPENSEARCH_INITIAL_ADMIN_PASSWORD=Admin1234! \
  apt-get install -y opensearch

# Disable the security plugin — PoC only; re-enable with TLS in production
echo 'plugins.security.disabled: true' \
  | sudo tee -a /etc/opensearch/opensearch.yml

sudo systemctl enable --now opensearch
```

Verify: `curl -s http://localhost:9200/_cluster/health | python3 -m json.tool`

### 3.4 RabbitMQ 3

```bash
sudo apt-get install -y rabbitmq-server
sudo systemctl enable --now rabbitmq-server
```

Verify: `sudo rabbitmq-diagnostics ping`

### 3.5 MinIO

MinIO ships as a single static binary.

```bash
sudo curl -Lo /usr/local/bin/minio \
  https://dl.min.io/server/minio/release/linux-amd64/minio
sudo chmod +x /usr/local/bin/minio

# Data directory
mkdir -p ~/minio/data
```

MinIO will be managed by Supervisor (§6).  To start it manually for testing:

```bash
MINIO_ROOT_USER=minio MINIO_ROOT_PASSWORD=minio123456 \
  minio server ~/minio/data --console-address ":9001"
```

Verify: `curl -s http://localhost:9000/minio/health/live`  → HTTP 200

---

## 4. Project Layout — Create All Files

Create the project root and virtualenv:

```bash
mkdir -p ~/invenio-rdm
cd ~/invenio-rdm
python3.9 -m venv venv
source venv/bin/activate
pip install --upgrade pip
```

Set the instance path (add to `~/.bashrc` to persist):

```bash
export INVENIO_INSTANCE_PATH=~/invenio-instance
mkdir -p $INVENIO_INSTANCE_PATH/{static,data,archive,assets/less,assets/templates/custom_fields}
echo 'export INVENIO_INSTANCE_PATH=~/invenio-instance' >> ~/.bashrc
```

Now create every file in the project by copying the blocks below.

---

### 4.1 `requirements.txt`

```
~/invenio-rdm/requirements.txt
```

```text
# InvenioRDM v12 (LTS) with OpenSearch 2 support.
invenio-app-rdm[opensearch2]~=12.0

# S3/MinIO file storage backend.
# Pin to v1.x — v2.x requires invenio-files-rest>=3.0 which conflicts with v12.
invenio-s3>=1.0.0,<2.0.0

# WSGI server
uWSGI==2.0.23

# Used by scripts/ingest.py and scripts/setup.sh
boto3==1.34.0
requests==2.31.0
```

Install:

```bash
pip install -r ~/invenio-rdm/requirements.txt
```

---

### 4.2 `invenio.cfg`

```
~/invenio-instance/invenio.cfg
```

```python
"""
InvenioRDM instance configuration — native (no Docker) setup.
All services run on localhost.
"""
import json
import os

# ─── Core Flask ───────────────────────────────────────────────────────────────
SECRET_KEY = os.environ.get("INVENIO_SECRET_KEY", "CHANGE-ME-IN-PRODUCTION")
APP_ALLOWED_HOSTS = ["localhost", "127.0.0.1", "0.0.0.0"]
SESSION_COOKIE_SECURE = False
APP_DEFAULT_SECURE_HEADERS = {
    "force_https": False,
    "force_https_permanent": False,
    "session_cookie_secure": False,
}

# ─── Site branding ────────────────────────────────────────────────────────────
THEME_SITENAME = "Research Data Repository"
THEME_FRONTPAGE_TITLE = "Research Data Repository"
THEME_FRONTPAGE_SUBTITLE = "Secure, self-hosted long-term preservation"
THEME_LOGO = "images/invenio-rdm.svg"

# ─── Site URLs ────────────────────────────────────────────────────────────────
# Must match what the browser uses — all API response links are built from these.
SITE_UI_URL  = "http://localhost"
SITE_API_URL = "http://localhost/api"

# ─── Database (PostgreSQL) ────────────────────────────────────────────────────
SQLALCHEMY_DATABASE_URI = "postgresql+psycopg2://invenio:invenio@localhost/invenio"

# ─── Cache & sessions (Redis) ─────────────────────────────────────────────────
CACHE_REDIS_URL                        = "redis://localhost:6379/0"
ACCOUNTS_SESSION_REDIS_URL             = "redis://localhost:6379/0"
COMMUNITIES_IDENTITIES_CACHE_REDIS_URL = "redis://localhost:6379/0"
RATELIMIT_STORAGE_URI                  = "redis://localhost:6379/3"

# ─── Celery ───────────────────────────────────────────────────────────────────
CELERY_BROKER_URL     = "amqp://guest:guest@localhost:5672/"
CELERY_RESULT_BACKEND = "redis://localhost:6379/2"

# ─── Search (OpenSearch 2) ────────────────────────────────────────────────────
SEARCH_ELASTIC_HOSTS = [{"host": "localhost", "port": 9200}]

# ─── File storage (MinIO / S3-compatible) ─────────────────────────────────────
FILES_REST_STORAGE_FACTORY = "invenio_s3.storage.s3fs_storage_factory"
S3_ENDPOINT_URL      = "http://localhost:9000"
S3_ACCESS_KEY_ID     = "minio"
S3_SECRET_ACCESS_KEY = "minio123456"
S3_REGION_NAME       = ""

# ─── Access control defaults ──────────────────────────────────────────────────
RDM_DEFAULT_FILES_RESTRICTION_ENABLED = True
RDM_ALLOW_METADATA_ONLY_RECORDS       = True

# ─── Email — disabled for PoC ─────────────────────────────────────────────────
MAIL_SUPPRESS_SEND = True
```

---

### 4.3 `src/wsgi_ui.py`

```
~/invenio-rdm/src/wsgi_ui.py
```

```python
"""WSGI entry point for the InvenioRDM UI application."""
from invenio_app.factory import create_ui

application = create_ui()
```

### 4.4 `src/wsgi_rest.py`

```
~/invenio-rdm/src/wsgi_rest.py
```

```python
"""WSGI entry point for the InvenioRDM REST API application."""
from invenio_app.factory import create_api

application = create_api()
```

---

### 4.5 `instance/uwsgi_ui.ini`

```
~/invenio-instance/uwsgi_ui.ini
```

```ini
[uwsgi]
module         = wsgi_ui:application
chdir          = /home/YOUR_USER/invenio-rdm/src

master                    = true
single-interpreter        = true
lazy-apps                 = true
processes                 = 2
threads                   = 4
http-socket               = 127.0.0.1:5000
wsgi-disable-file-wrapper = true
thunder-lock              = true
buffer-size               = 65535
post-buffering            = 4096
req-logger                = stdio
logger                    = stdio
```

> Replace `YOUR_USER` with your actual Linux username.

### 4.6 `instance/uwsgi_rest.ini`

```
~/invenio-instance/uwsgi_rest.ini
```

```ini
[uwsgi]
module         = wsgi_rest:application
chdir          = /home/YOUR_USER/invenio-rdm/src

master                    = true
single-interpreter        = true
lazy-apps                 = true
processes                 = 2
threads                   = 4
http-socket               = 127.0.0.1:5001
wsgi-disable-file-wrapper = true
thunder-lock              = true
buffer-size               = 65535
post-buffering            = 4096
req-logger                = stdio
logger                    = stdio
```

---

### 4.7 Nginx virtual host

```
/etc/nginx/sites-available/invenio
```

```nginx
upstream ui_server  { server 127.0.0.1:5000 fail_timeout=0; }
upstream api_server { server 127.0.0.1:5001 fail_timeout=0; }

server {
    listen 80;
    server_name localhost;

    charset utf-8;
    keepalive_timeout 5;
    client_max_body_size 512m;

    # Compiled frontend assets served directly (no app round-trip)
    location /static {
        alias /home/YOUR_USER/invenio-instance/static;
        autoindex off;
        expires 1d;
        add_header Cache-Control "public";
    }

    # REST API — strip /api prefix before forwarding.
    # create_api() registers routes at / (e.g. /records, not /api/records).
    location /api {
        rewrite ^/api/?(.*)$ /$1 break;
        proxy_set_header Host              $host;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_redirect   off;
        proxy_buffering  off;
        proxy_pass       http://api_server;
    }

    # UI — everything else
    location / {
        proxy_set_header Host              $host;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_redirect   off;
        proxy_buffering  off;
        proxy_pass       http://ui_server;
    }
}
```

> Replace `YOUR_USER` with your Linux username.

Enable it:

```bash
sudo ln -sf /etc/nginx/sites-available/invenio /etc/nginx/sites-enabled/invenio
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t && sudo systemctl reload nginx
```

---

### 4.8 `assets/theme.config`

This file is required by the webpack build. InvenioRDM's `invenio webpack create`
does not generate it for bare (non-cookiecutter) installations — it must be
placed manually.

```
~/invenio-instance/assets/less/theme.config
```

```less
/*
 * Semantic UI / InvenioRDM theme configuration.
 * Required by the webpack build (aliased as "../../theme.config"
 * from within semantic-ui-less). Not generated by `invenio webpack create`
 * for bare installations — must be provided manually.
 */

/* Global */
@site        : 'invenio';
@reset       : 'default';

/* Elements */
@button      : 'invenio';
@container   : 'invenio';
@divider     : 'invenio';
@flag        : 'invenio';
@header      : 'invenio';
@icon        : 'default';
@image       : 'invenio';
@input       : 'invenio';
@label       : 'invenio';
@list        : 'invenio';
@loader      : 'invenio';
@placeholder : 'invenio';
@rail        : 'invenio';
@reveal      : 'invenio';
@segment     : 'invenio';
@step        : 'invenio';

/* Collections */
@breadcrumb  : 'invenio';
@form        : 'invenio';
@grid        : 'invenio';
@menu        : 'invenio';
@message     : 'invenio';
@table       : 'invenio';

/* Modules */
@accordion   : 'invenio';
@checkbox    : 'invenio';
@dimmer      : 'invenio';
@dropdown    : 'invenio';
@embed       : 'invenio';
@modal       : 'invenio';
@nag         : 'invenio';
@popup       : 'invenio';
@progress    : 'invenio';
@rating      : 'invenio';
@search      : 'invenio';
@shape       : 'invenio';
@sidebar     : 'invenio';
@sticky      : 'invenio';
@tab         : 'invenio';
@transition  : 'invenio';

/* Views */
@ad          : 'invenio';
@card        : 'invenio';
@comment     : 'invenio';
@feed        : 'invenio';
@item        : 'invenio';
@statistic   : 'invenio';

/* Path to theme packages */
@themesFolder : '~semantic-ui-less/themes';

/* Path to site override folder (all imports are optional) */
@siteFolder  : '../../less/site';

/* Use the invenio-app-rdm theme chain */
@import (multiple) "themes/rdm/theme.less";

@fontPath : "../../../themes/@{theme}/assets/fonts";
```

---

### 4.9 `scripts/setup.sh`

One-time bootstrapping script. Run it once after all services are up.

```
~/invenio-rdm/scripts/setup.sh
```

```bash
#!/usr/bin/env bash
# setup.sh — One-time initialisation of an InvenioRDM instance (native / no Docker).
# Usage: bash ~/invenio-rdm/scripts/setup.sh
set -euo pipefail

ADMIN_EMAIL="${INVENIO_ADMIN_EMAIL:-admin@example.com}"
ADMIN_PASSWORD="${INVENIO_ADMIN_PASSWORD:-Admin1234!}"
MINIO_ENDPOINT="${INVENIO_S3_ENDPOINT_URL:-http://localhost:9000}"
MINIO_USER="${INVENIO_S3_ACCESS_KEY_ID:-minio}"
MINIO_PASS="${INVENIO_S3_SECRET_ACCESS_KEY:-minio123456}"
BUCKET_NAME="default"

log() { echo "[setup] $*"; }

wait_for() {
    local host=$1 port=$2
    log "Waiting for $host:$port …"
    until nc -z "$host" "$port" 2>/dev/null; do sleep 3; done
    log "$host:$port is up."
}

# ── Wait for services ─────────────────────────────────────────────────────────
wait_for localhost 5432
wait_for localhost 9200
wait_for localhost 6379
wait_for localhost 5672
wait_for localhost 9000

# ── MinIO bucket ──────────────────────────────────────────────────────────────
log "Creating MinIO bucket '$BUCKET_NAME' …"
python3 - <<PYEOF
import boto3
from botocore.exceptions import ClientError

s3 = boto3.client(
    "s3",
    endpoint_url="${MINIO_ENDPOINT}",
    aws_access_key_id="${MINIO_USER}",
    aws_secret_access_key="${MINIO_PASS}",
    region_name="",
)
try:
    s3.create_bucket(Bucket="${BUCKET_NAME}")
    print("  Bucket '${BUCKET_NAME}' created.")
except ClientError as e:
    code = e.response["Error"]["Code"]
    if code in ("BucketAlreadyOwnedByYou", "BucketAlreadyExists"):
        print("  Bucket already exists — skipping.")
    else:
        raise
PYEOF

# ── Database ──────────────────────────────────────────────────────────────────
log "Creating database tables …"
invenio db create --verbose

# ── Search indices ────────────────────────────────────────────────────────────
log "Creating OpenSearch indices …"
invenio index destroy --yes-i-know 2>/dev/null || true
invenio index init --force

# ── File storage location ─────────────────────────────────────────────────────
log "Registering S3 storage location …"
invenio files location create --default default "s3://${BUCKET_NAME}" || \
    log "Location already exists — skipping."

# ── Vocabularies & fixtures ───────────────────────────────────────────────────
log "Loading vocabularies …"
invenio rdm fixtures
invenio rdm-records fixtures || log "rdm-records fixtures failed (demo users) — non-fatal."

# ── Frontend assets ───────────────────────────────────────────────────────────
log "Building frontend assets (this takes a few minutes) …"
invenio collect -v
invenio webpack create

# Ensure theme.config and custom_fields dir are in place
ASSETS="${INVENIO_INSTANCE_PATH}/assets"
mkdir -p "${ASSETS}/less" "${ASSETS}/templates/custom_fields"

if [ ! -f "${ASSETS}/less/theme.config" ]; then
    log "ERROR: ${ASSETS}/less/theme.config not found."
    log "       Create it from section 4.8 of SETUP_NATIVE.md, then re-run."
    exit 1
fi

invenio webpack install
invenio webpack buildall

# ── Admin user ────────────────────────────────────────────────────────────────
log "Creating admin user '$ADMIN_EMAIL' …"
invenio users create "$ADMIN_EMAIL" --password "$ADMIN_PASSWORD" --active || \
    log "User already exists — skipping."
invenio roles create admin || log "Role 'admin' already exists."
invenio roles add "$ADMIN_EMAIL" admin || log "Role already assigned."
invenio access allow superuser-access user "$ADMIN_EMAIL" || \
    log "Superuser access already granted."

log "Confirming admin user (bypasses email verification) …"
invenio shell --no-term-title -c "
from invenio_accounts.models import User
from invenio_db import db
import datetime
u = User.query.filter_by(email='$ADMIN_EMAIL').first()
if u and not u.confirmed_at:
    u.confirmed_at = datetime.datetime.utcnow()
    db.session.commit()
    print('  Confirmed.')
else:
    print('  Already confirmed.')
"

# ── Done ──────────────────────────────────────────────────────────────────────
log "================================================"
log "Setup complete!"
log "  UI  → http://localhost"
log "  API → http://localhost/api/records"
log "  Admin: $ADMIN_EMAIL / $ADMIN_PASSWORD"
log "================================================"
log "Next: create an API token at"
log "  http://localhost/account/settings/applications/tokens/new/"
log "then run:  python scripts/ingest.py --token <token> --base-url http://localhost:5001 --no-api-prefix"
```

Make it executable:

```bash
chmod +x ~/invenio-rdm/scripts/setup.sh
```

---

### 4.10 `scripts/ingest.py`

Uploads the Iris dataset package to InvenioRDM via the REST API.

```
~/invenio-rdm/scripts/ingest.py
```

```python
#!/usr/bin/env python3
"""
ingest.py — Upload the Iris dataset package to InvenioRDM via REST API.

Usage (native):
    python scripts/ingest.py \
        --token <PERSONAL_ACCESS_TOKEN> \
        --base-url http://localhost:5001 \
        --no-api-prefix

The token is created at:
    http://localhost/account/settings/applications/tokens/new/
"""

import argparse
import hashlib
import json
import sys
from pathlib import Path

import requests
import urllib3

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

DATASET_DIR = Path(__file__).parent.parent / "datasets" / "iris"
FILES_TO_UPLOAD = ["data.csv", "schema.json", "README.md"]


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    h.update(path.read_bytes())
    return h.hexdigest()


def api(base_url: str, token: str):
    session = requests.Session()
    session.headers.update({
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
        # Satisfy InvenioRDM trusted-host check when calling the API server
        # directly (bypassing nginx) — the Host header must match APP_ALLOWED_HOSTS.
        "Host": "localhost",
    })
    session.verify = False
    return session, base_url.rstrip("/")


def create_draft(session, base: str, metadata: dict) -> str:
    r = session.post(f"{base}/records", json=metadata)
    r.raise_for_status()
    record_id = r.json()["id"]
    print(f"[ingest] Draft created: id={record_id}")
    return record_id


def upload_files(session, base: str, record_id: str, files: list[Path]):
    entries = [{"key": f.name} for f in files]
    r = session.post(f"{base}/records/{record_id}/draft/files", json=entries)
    r.raise_for_status()

    for path in files:
        key = path.name
        content = path.read_bytes()

        # Temporarily swap Content-Type for the binary upload, then restore it
        prev_ct = session.headers.pop("Content-Type", None)
        session.headers["Content-Type"] = "application/octet-stream"
        r = session.put(
            f"{base}/records/{record_id}/draft/files/{key}/content",
            data=content,
        )
        session.headers["Content-Type"] = prev_ct or "application/json"
        r.raise_for_status()

        r = session.post(f"{base}/records/{record_id}/draft/files/{key}/commit")
        r.raise_for_status()
        print(f"[ingest]   uploaded {key}  sha256={sha256(path)[:16]}…")


def publish(session, base: str, record_id: str) -> str:
    r = session.post(f"{base}/records/{record_id}/draft/actions/publish")
    r.raise_for_status()
    data = r.json()
    doi = data.get("pids", {}).get("doi", {}).get("identifier", "—")
    url = data.get("links", {}).get("self_html", f"{base}/records/{record_id}")
    print(f"[ingest] Published!  DOI={doi}")
    print(f"[ingest] Record URL: {url}")
    return record_id


def write_checksums(files: list[Path]):
    out = DATASET_DIR / "checksums.txt"
    lines = [f"sha256:{sha256(f)}  {f.name}" for f in files]
    out.write_text("\n".join(lines) + "\n")
    print(f"[ingest] Checksums written to {out}")


def main():
    parser = argparse.ArgumentParser(description="Ingest Iris dataset into InvenioRDM")
    parser.add_argument("--token", required=True, help="Personal access token")
    parser.add_argument("--base-url", default="http://localhost",
                        help="InvenioRDM base URL (default: http://localhost)")
    parser.add_argument("--no-api-prefix", action="store_true",
                        help="Omit /api prefix — required when calling the API "
                             "server directly on :5001 (nginx is not in the path)")
    args = parser.parse_args()

    api_prefix = "" if args.no_api_prefix else "/api"

    metadata_path = DATASET_DIR / "metadata.json"
    if not metadata_path.exists():
        sys.exit(f"[ingest] ERROR: {metadata_path} not found.")
    metadata = json.loads(metadata_path.read_text())

    files = [DATASET_DIR / f for f in FILES_TO_UPLOAD]
    missing = [str(f) for f in files if not f.exists()]
    if missing:
        sys.exit(f"[ingest] ERROR: missing files: {missing}")

    write_checksums(files)

    session, base = api(args.base_url, args.token)
    print(f"[ingest] Connecting to {base} …")
    record_id = create_draft(session, f"{base}{api_prefix}", metadata)
    upload_files(session, f"{base}{api_prefix}", record_id, files)
    publish(session, f"{base}{api_prefix}", record_id)
    print("[ingest] Done.")


if __name__ == "__main__":
    main()
```

---

### 4.11 `scripts/api_preview.py`

Fetches the Iris dataset from the API and prints a formatted console preview.

```
~/invenio-rdm/scripts/api_preview.py
```

```python
#!/usr/bin/env python3
"""
api_preview.py — Query the InvenioRDM REST API for the Iris dataset and
                  print a formatted console preview of the record metadata
                  and the first rows of data.csv.

Usage:
    python scripts/api_preview.py
"""

import sys
import requests

# Target the API server directly (no nginx in the path)
API_BASE     = "http://localhost:5001"
PREVIEW_ROWS = 10


def _get(path: str, **kwargs) -> requests.Response:
    r = requests.get(f"{API_BASE}{path}", headers={"Host": "localhost"}, **kwargs)
    r.raise_for_status()
    return r


def print_section(title: str):
    print(f"\n{'─' * 60}")
    print(f"  {title}")
    print(f"{'─' * 60}")


def print_metadata(rec: dict):
    meta  = rec["metadata"]
    files = rec["files"]["entries"]
    links = rec["links"]

    print_section("📋  Record Metadata")
    print(f"  ID          : {rec['id']}")
    print(f"  Title       : {meta['title']}")
    print(f"  Date        : {meta['publication_date']}")
    creators = meta.get("creators", [])
    names = ", ".join(
        c["person_or_org"].get("name")
        or f"{c['person_or_org'].get('family_name')}, {c['person_or_org'].get('given_name')}"
        for c in creators
    )
    print(f"  Creators    : {names}")
    print(f"  Files       : {', '.join(files.keys())}")
    print(f"  Record URL  : {links['self_html']}")


def print_csv_preview(rec_id: str):
    print_section(f"📊  data.csv  (first {PREVIEW_ROWS} rows)")

    # The content endpoint returns a short-lived presigned MinIO URL
    url_resp  = _get(f"/records/{rec_id}/files/data.csv/content")
    minio_url = url_resp.text.strip()
    csv_text  = requests.get(minio_url).text
    lines     = csv_text.splitlines()

    header     = lines[0].split(",")
    rows       = [line.split(",") for line in lines[1: PREVIEW_ROWS + 1]]
    total_rows = len(lines) - 1

    widths = [
        max(len(h), max((len(r[i]) for r in rows if i < len(r)), default=0))
        for i, h in enumerate(header)
    ]

    def fmt(cells):
        return "  " + "  ".join(c.ljust(widths[i]) for i, c in enumerate(cells))

    print(fmt(header))
    print("  " + "  ".join("─" * w for w in widths))
    for row in rows:
        print(fmt(row))

    if total_rows > PREVIEW_ROWS:
        print(f"\n  … {total_rows - PREVIEW_ROWS} more rows ({total_rows} total)")


def main():
    resp  = _get("/records?q=iris&sort=newest&size=1")
    data  = resp.json()
    hits  = data["hits"]["hits"]
    total = data["hits"]["total"]

    if total == 0:
        sys.exit("[api] No records found. Run ingest.py first.")

    print(f"\n[api] Found {total} record(s). Showing most recent:")
    rec = hits[0]
    print_metadata(rec)
    print_csv_preview(rec["id"])
    print()


if __name__ == "__main__":
    main()
```

---

### 4.12 `datasets/iris/metadata.json`

```
~/invenio-rdm/datasets/iris/metadata.json
```

```json
{
  "access": {
    "record": "public",
    "files": "public"
  },
  "files": {
    "enabled": true
  },
  "metadata": {
    "resource_type": { "id": "dataset" },
    "title": "Iris Flower Dataset — Fisher (1936)",
    "description": "Classic morphometric dataset collected by Edgar Anderson and analysed by Ronald A. Fisher in his 1936 paper 'The use of multiple measurements in taxonomic problems'. Contains 150 observations of sepal and petal dimensions across three Iris species: setosa, versicolor, and virginica. Widely used as a benchmark in pattern recognition and machine learning.",
    "publication_date": "1936-01-01",
    "creators": [
      {
        "person_or_org": {
          "type": "personal",
          "family_name": "Fisher",
          "given_name": "Ronald A."
        }
      },
      {
        "person_or_org": {
          "type": "personal",
          "family_name": "Anderson",
          "given_name": "Edgar"
        }
      }
    ],
    "rights": [
      { "id": "cc-by-4.0" }
    ],
    "languages": [
      { "id": "eng" }
    ],
    "subjects": [
      { "subject": "botany" },
      { "subject": "morphometrics" },
      { "subject": "machine learning" },
      { "subject": "pattern recognition" }
    ],
    "version": "1.0.0",
    "identifiers": [
      {
        "identifier": "https://archive.ics.uci.edu/ml/datasets/iris",
        "scheme": "url"
      }
    ]
  }
}
```

---

### 4.13 `datasets/iris/schema.json`

```
~/invenio-rdm/datasets/iris/schema.json
```

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "title": "Iris Flower Measurement Dataset",
  "description": "Schema for Fisher's Iris flower morphometric measurements.",
  "type": "object",
  "properties": {
    "sepal_length": {
      "type": "number",
      "description": "Sepal length in centimetres",
      "unit": "cm",
      "minimum": 0
    },
    "sepal_width": {
      "type": "number",
      "description": "Sepal width in centimetres",
      "unit": "cm",
      "minimum": 0
    },
    "petal_length": {
      "type": "number",
      "description": "Petal length in centimetres",
      "unit": "cm",
      "minimum": 0
    },
    "petal_width": {
      "type": "number",
      "description": "Petal width in centimetres",
      "unit": "cm",
      "minimum": 0
    },
    "species": {
      "type": "string",
      "description": "Iris species",
      "enum": ["setosa", "versicolor", "virginica"]
    }
  },
  "required": ["sepal_length", "sepal_width", "petal_length", "petal_width", "species"]
}
```

---

### 4.14 `datasets/iris/README.md`

```
~/invenio-rdm/datasets/iris/README.md
```

```markdown
# Iris Flower Dataset

**Source:** UCI Machine Learning Repository
**Original paper:** Fisher, R.A. (1936). *The use of multiple measurements in taxonomic problems.* Annals of Eugenics, 7(2), 179–188.
**License:** CC BY 4.0

## Description

150 observations of Iris flower morphometrics across three species:

| Species | Count |
|---------|-------|
| *Iris setosa* | 50 |
| *Iris versicolor* | 50 |
| *Iris virginica* | 50 |

## File contents

| File | Description |
|------|-------------|
| `data.csv` | 150 rows × 5 columns (see schema below) |
| `schema.json` | JSON Schema describing column types and units |
| `metadata.json` | InvenioRDM record metadata (used for ingestion) |
| `checksums.txt` | SHA-256 checksums for fixity verification |

## Schema

| Column | Type | Unit | Description |
|--------|------|------|-------------|
| `sepal_length` | float | cm | Length of the sepal |
| `sepal_width` | float | cm | Width of the sepal |
| `petal_length` | float | cm | Length of the petal |
| `petal_width` | float | cm | Width of the petal |
| `species` | string | — | Iris species (setosa / versicolor / virginica) |

## Fixity

Run `sha256sum -c checksums.txt` to verify file integrity.
```

---

### 4.15 `datasets/iris/data.csv`

```
~/invenio-rdm/datasets/iris/data.csv
```

```csv
sepal_length,sepal_width,petal_length,petal_width,species
5.1,3.5,1.4,0.2,setosa
4.9,3.0,1.4,0.2,setosa
4.7,3.2,1.3,0.2,setosa
4.6,3.1,1.5,0.2,setosa
5.0,3.6,1.4,0.2,setosa
5.4,3.9,1.7,0.4,setosa
4.6,3.4,1.4,0.3,setosa
5.0,3.4,1.5,0.2,setosa
4.4,2.9,1.4,0.2,setosa
4.9,3.1,1.5,0.1,setosa
5.4,3.7,1.5,0.2,setosa
4.8,3.4,1.6,0.2,setosa
4.8,3.0,1.4,0.1,setosa
4.3,3.0,1.1,0.1,setosa
5.8,4.0,1.2,0.2,setosa
5.7,4.4,1.5,0.4,setosa
5.4,3.9,1.3,0.4,setosa
5.1,3.5,1.4,0.3,setosa
5.7,3.8,1.7,0.3,setosa
5.1,3.8,1.5,0.3,setosa
5.4,3.4,1.7,0.2,setosa
5.1,3.7,1.5,0.4,setosa
4.6,3.6,1.0,0.2,setosa
5.1,3.3,1.7,0.5,setosa
4.8,3.4,1.9,0.2,setosa
5.0,3.0,1.6,0.2,setosa
5.0,3.4,1.6,0.4,setosa
5.2,3.5,1.5,0.2,setosa
5.2,3.4,1.4,0.2,setosa
4.7,3.2,1.6,0.2,setosa
4.8,3.1,1.6,0.2,setosa
5.4,3.4,1.5,0.4,setosa
5.2,4.1,1.5,0.1,setosa
5.5,4.2,1.4,0.2,setosa
4.9,3.1,1.5,0.2,setosa
5.0,3.2,1.2,0.2,setosa
5.5,3.5,1.3,0.2,setosa
4.9,3.6,1.4,0.1,setosa
4.4,3.0,1.3,0.2,setosa
5.1,3.4,1.5,0.2,setosa
5.0,3.5,1.3,0.3,setosa
4.5,2.3,1.3,0.3,setosa
4.4,3.2,1.3,0.2,setosa
5.0,3.5,1.6,0.6,setosa
5.1,3.8,1.9,0.4,setosa
4.8,3.0,1.4,0.3,setosa
5.1,3.8,1.6,0.2,setosa
4.6,3.2,1.4,0.2,setosa
5.3,3.7,1.5,0.2,setosa
5.0,3.3,1.4,0.2,setosa
7.0,3.2,4.7,1.4,versicolor
6.4,3.2,4.5,1.5,versicolor
6.9,3.1,4.9,1.5,versicolor
5.5,2.3,4.0,1.3,versicolor
6.5,2.8,4.6,1.5,versicolor
5.7,2.8,4.5,1.3,versicolor
6.3,3.3,4.7,1.6,versicolor
4.9,2.4,3.3,1.0,versicolor
6.6,2.9,4.6,1.3,versicolor
5.2,2.7,3.9,1.4,versicolor
5.0,2.0,3.5,1.0,versicolor
5.9,3.0,4.2,1.5,versicolor
6.0,2.2,4.0,1.0,versicolor
6.1,2.9,4.7,1.4,versicolor
5.6,2.9,3.6,1.3,versicolor
6.7,3.1,4.4,1.4,versicolor
5.6,3.0,4.5,1.5,versicolor
5.8,2.7,4.1,1.0,versicolor
6.2,2.2,4.5,1.5,versicolor
5.6,2.5,3.9,1.1,versicolor
5.9,3.2,4.8,1.8,versicolor
6.1,2.8,4.0,1.3,versicolor
6.3,2.5,4.9,1.5,versicolor
6.1,2.8,4.7,1.2,versicolor
6.4,2.9,4.3,1.3,versicolor
6.6,3.0,4.4,1.4,versicolor
6.8,2.8,4.8,1.4,versicolor
6.7,3.0,5.0,1.7,versicolor
6.0,2.9,4.5,1.5,versicolor
5.7,2.6,3.5,1.0,versicolor
5.5,2.4,3.8,1.1,versicolor
5.5,2.4,3.7,1.0,versicolor
5.8,2.7,3.9,1.2,versicolor
6.0,2.7,5.1,1.6,versicolor
5.4,3.0,4.5,1.5,versicolor
6.0,3.4,4.5,1.6,versicolor
6.7,3.1,4.7,1.5,versicolor
6.3,2.3,4.4,1.3,versicolor
5.6,3.0,4.1,1.3,versicolor
5.5,2.5,4.0,1.3,versicolor
5.5,2.6,4.4,1.2,versicolor
6.1,3.0,4.6,1.4,versicolor
5.8,2.6,4.0,1.2,versicolor
5.0,2.3,3.3,1.0,versicolor
5.6,2.7,4.2,1.3,versicolor
5.7,3.0,4.2,1.2,versicolor
5.7,2.9,4.2,1.3,versicolor
6.2,2.9,4.3,1.3,versicolor
5.1,2.5,3.0,1.1,versicolor
5.7,2.8,4.1,1.3,versicolor
6.3,3.3,6.0,2.5,virginica
5.8,2.7,5.1,1.9,virginica
7.1,3.0,5.9,2.1,virginica
6.3,2.9,5.6,1.8,virginica
6.5,3.0,5.8,2.2,virginica
7.6,3.0,6.6,2.1,virginica
4.9,2.5,4.5,1.7,virginica
7.3,2.9,6.3,1.8,virginica
6.7,2.5,5.8,1.8,virginica
7.2,3.6,6.1,2.5,virginica
6.5,3.2,5.1,2.0,virginica
6.4,2.7,5.3,1.9,virginica
6.8,3.0,5.5,2.1,virginica
5.7,2.5,5.0,2.0,virginica
5.8,2.8,5.1,2.4,virginica
6.4,3.2,5.3,2.3,virginica
6.5,3.0,5.5,1.8,virginica
7.7,3.8,6.7,2.2,virginica
7.7,2.6,6.9,2.3,virginica
6.0,2.2,5.0,1.5,virginica
6.9,3.2,5.7,2.3,virginica
5.6,2.8,4.9,2.0,virginica
7.7,2.8,6.7,2.0,virginica
6.3,2.7,4.9,1.8,virginica
6.7,3.3,5.7,2.1,virginica
7.2,3.2,6.0,1.8,virginica
6.2,2.8,4.8,1.8,virginica
6.1,3.0,4.9,1.8,virginica
6.4,2.8,5.6,2.1,virginica
7.2,3.0,5.8,1.6,virginica
7.4,2.8,6.1,1.9,virginica
7.9,3.8,6.4,2.0,virginica
6.4,2.8,5.6,2.2,virginica
6.3,2.8,5.1,1.5,virginica
6.1,2.6,5.6,1.4,virginica
7.7,3.0,6.1,2.3,virginica
6.3,3.4,5.6,2.4,virginica
6.4,3.1,5.5,1.8,virginica
6.0,3.0,4.8,1.8,virginica
6.9,3.1,5.4,2.1,virginica
6.7,3.1,5.6,2.4,virginica
6.9,3.1,5.1,2.3,virginica
5.8,2.7,5.1,1.9,virginica
6.8,3.2,5.9,2.3,virginica
6.7,3.3,5.7,2.5,virginica
6.7,3.0,5.2,2.3,virginica
6.3,2.5,5.0,1.9,virginica
6.5,3.0,5.2,2.0,virginica
6.2,3.4,5.4,2.3,virginica
5.9,3.0,5.1,1.8,virginica
```

---

## 5. One-time Initialisation

Make sure all infrastructure services (§3) are running and the virtualenv is
active, then run the setup script once:

```bash
source ~/invenio-venv/bin/activate
export INVENIO_INSTANCE_PATH=~/invenio-instance

bash ~/invenio-rdm/scripts/setup.sh
```

The script will:

1. Wait for all services to be reachable
2. Create the MinIO `default` bucket
3. Create all PostgreSQL tables (`invenio db create`)
4. Create OpenSearch indices (`invenio index init`)
5. Register the MinIO bucket as default file storage location
6. Load vocabularies (resource types, licences, languages, subject types)
7. Build the webpack frontend (CSS + JS — takes ~5 minutes on first run)
8. Create and confirm the admin user

Expected final output:

```
[setup] ================================================
[setup] Setup complete!
[setup]   UI  → http://localhost
[setup]   API → http://localhost/api/records
[setup]   Admin: admin@example.com / Admin1234!
[setup] ================================================
```

---

## 6. Running the Application

All four application processes are managed by Supervisor.

### 6.1 `supervisord.conf`

Create `~/invenio-supervisor.conf`:

```ini
[supervisord]
nodaemon=false
logfile=/tmp/supervisord.log
pidfile=/tmp/supervisord.pid

[supervisorctl]
serverurl=unix:///tmp/supervisor.sock

[unix_http_server]
file=/tmp/supervisor.sock

[rpcinterface:supervisor]
supervisor.rpcinterface_factory = supervisor.rpcinterface:make_main_rpcinterface

; ── InvenioRDM UI (uWSGI :5000) ───────────────────────────────────────────────
[program:invenio-ui]
command=/home/%(ENV_USER)s/invenio-venv/bin/uwsgi
        /home/%(ENV_USER)s/invenio-instance/uwsgi_ui.ini
environment=INVENIO_INSTANCE_PATH="/home/%(ENV_USER)s/invenio-instance"
directory=/home/%(ENV_USER)s/invenio-rdm/src
autostart=true
autorestart=true
stdout_logfile=/tmp/invenio-ui.log
stderr_logfile=/tmp/invenio-ui.log

; ── InvenioRDM REST API (uWSGI :5001) ────────────────────────────────────────
[program:invenio-api]
command=/home/%(ENV_USER)s/invenio-venv/bin/uwsgi
        /home/%(ENV_USER)s/invenio-instance/uwsgi_rest.ini
environment=INVENIO_INSTANCE_PATH="/home/%(ENV_USER)s/invenio-instance"
directory=/home/%(ENV_USER)s/invenio-rdm/src
autostart=true
autorestart=true
stdout_logfile=/tmp/invenio-api.log
stderr_logfile=/tmp/invenio-api.log

; ── Celery worker ─────────────────────────────────────────────────────────────
[program:celery]
command=/home/%(ENV_USER)s/invenio-venv/bin/celery
        -A invenio_app.celery worker --loglevel=INFO --concurrency=2
environment=INVENIO_INSTANCE_PATH="/home/%(ENV_USER)s/invenio-instance"
directory=/home/%(ENV_USER)s/invenio-rdm/src
autostart=true
autorestart=true
stdout_logfile=/tmp/celery.log
stderr_logfile=/tmp/celery.log

; ── MinIO object storage ──────────────────────────────────────────────────────
[program:minio]
command=minio server /home/%(ENV_USER)s/minio/data --console-address ":9001"
environment=MINIO_ROOT_USER="minio",MINIO_ROOT_PASSWORD="minio123456"
autostart=true
autorestart=true
stdout_logfile=/tmp/minio.log
stderr_logfile=/tmp/minio.log
```

### 6.2 Start

```bash
source ~/invenio-venv/bin/activate

supervisord -c ~/invenio-supervisor.conf
supervisorctl -c ~/invenio-supervisor.conf status
```

Expected output:

```
celery        RUNNING   pid 12345, uptime 0:00:03
invenio-api   RUNNING   pid 12346, uptime 0:00:03
invenio-ui    RUNNING   pid 12347, uptime 0:00:03
minio         RUNNING   pid 12348, uptime 0:00:03
```

### 6.3 Useful Supervisor commands

```bash
# Check status
supervisorctl -c ~/invenio-supervisor.conf status

# Tail logs
tail -f /tmp/invenio-ui.log
tail -f /tmp/invenio-api.log
tail -f /tmp/celery.log

# Restart a process
supervisorctl -c ~/invenio-supervisor.conf restart invenio-api

# Stop everything
supervisorctl -c ~/invenio-supervisor.conf shutdown
```

### 6.4 Smoke test

```bash
curl -s http://localhost/api/records | python3 -m json.tool | head -15
```

---

## 7. Ingest the Iris Dataset

### 7.1 Create a personal API token

Open: **http://localhost/account/settings/applications/tokens/new/**

Enter any name (e.g. `cli`), click **Save**, and copy the token shown.

### 7.2 Run the ingest script

```bash
source ~/invenio-venv/bin/activate
export INVENIO_INSTANCE_PATH=~/invenio-instance

python ~/invenio-rdm/scripts/ingest.py \
    --token  <YOUR_TOKEN_HERE> \
    --base-url http://localhost:5001 \
    --no-api-prefix
```

Expected output:

```
[ingest] Checksums written to …/datasets/iris/checksums.txt
[ingest] Connecting to http://localhost:5001 …
[ingest] Draft created: id=xxxxx-xxxxx
[ingest]   uploaded data.csv    sha256=9cc1c345c71bcc9b…
[ingest]   uploaded schema.json sha256=62dc9eb66d0e748b…
[ingest]   uploaded README.md   sha256=4c0814255dd08100…
[ingest] Published!  DOI=—
[ingest] Record URL: http://localhost/records/xxxxx-xxxxx
[ingest] Done.
```

> **Why `--base-url http://localhost:5001 --no-api-prefix`?**  
> `ingest.py` calls the API server directly, bypassing nginx. The API server
> (`create_api()`) registers routes at `/records` — not `/api/records`.
> `--no-api-prefix` omits the `/api` segment that nginx would normally strip.
> The `Host: localhost` header is injected automatically to satisfy
> InvenioRDM's trusted-host check.

---

## 8. API Preview

```bash
source ~/invenio-venv/bin/activate
export INVENIO_INSTANCE_PATH=~/invenio-instance

python ~/invenio-rdm/scripts/api_preview.py
```

Expected output:

```
[api] Found 1 record(s). Showing most recent:

────────────────────────────────────────────────────────────
  📋  Record Metadata
────────────────────────────────────────────────────────────
  ID          : xxxxx-xxxxx
  Title       : Iris Flower Dataset — Fisher (1936)
  Date        : 1936-01-01
  Creators    : Fisher, Ronald A., Anderson, Edgar
  Files       : data.csv, schema.json, README.md
  Record URL  : http://localhost/records/xxxxx-xxxxx

────────────────────────────────────────────────────────────
  📊  data.csv  (first 10 rows)
────────────────────────────────────────────────────────────
  sepal_length  sepal_width  petal_length  petal_width  species
  ────────────  ───────────  ────────────  ───────────  ───────
  5.1           3.5          1.4           0.2          setosa
  …
  … 140 more rows (150 total)
```

---

## 9. Quick Reference

| What | URL / Command |
|---|---|
| Repository UI | http://localhost |
| REST API | http://localhost/api/records |
| Admin login | admin@example.com / Admin1234! |
| Token creation | http://localhost/account/settings/applications/tokens/new/ |
| MinIO console | http://localhost:9001 (minio / minio123456) |
| RabbitMQ management | http://localhost:15672 (guest / guest) |
| OpenSearch health | http://localhost:9200/_cluster/health |
| Supervisor status | `supervisorctl -c ~/invenio-supervisor.conf status` |
| UI log | `tail -f /tmp/invenio-ui.log` |
| API log | `tail -f /tmp/invenio-api.log` |
| Celery log | `tail -f /tmp/celery.log` |

### Complete file tree

```
~/invenio-rdm/
├── requirements.txt
├── src/
│   ├── wsgi_ui.py
│   └── wsgi_rest.py
├── scripts/
│   ├── setup.sh
│   ├── ingest.py
│   └── api_preview.py
└── datasets/
    └── iris/
        ├── data.csv
        ├── schema.json
        ├── metadata.json
        ├── README.md
        └── checksums.txt          ← generated by ingest.py

~/invenio-instance/                ← INVENIO_INSTANCE_PATH
├── invenio.cfg
├── uwsgi_ui.ini
├── uwsgi_rest.ini
├── assets/
│   ├── less/
│   │   └── theme.config           ← required by webpack build
│   └── templates/
│       └── custom_fields/         ← empty dir, required by webpack
├── static/                        ← compiled by `invenio webpack buildall`
└── data/                          ← uploaded file fallback (not used with MinIO)

/etc/nginx/sites-available/invenio ← reverse proxy config
~/invenio-supervisor.conf          ← process manager
```
