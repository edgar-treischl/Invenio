# Copilot Instructions

## What This Repository Is

A self-contained setup guide (`outline.md`) for running **InvenioRDM v12** natively on Ubuntu 22.04 — no Docker for the application itself. All infrastructure services (PostgreSQL, Redis, OpenSearch, RabbitMQ, MinIO) run as native OS services. The repository contains only the guide; the actual application files are created by following it.

---

## Architecture

```
Browser
  └─▶ Nginx :80
        ├─▶ /static  → ~/invenio-instance/static/   (served directly)
        ├─▶ /api/*   → uWSGI :5001  (REST API, /api prefix stripped by nginx)
        └─▶ /*       → uWSGI :5000  (UI)

uWSGI :5000  ←→  invenio_app.factory.create_ui()
uWSGI :5001  ←→  invenio_app.factory.create_api()

Celery worker
  ├─▶ RabbitMQ :5672   (task queue / broker)
  └─▶ Redis    :6379/2 (result backend)

Both WSGI apps
  ├─▶ PostgreSQL  :5432  (metadata)
  ├─▶ OpenSearch  :9200  (full-text search)
  ├─▶ Redis       :6379  (cache, sessions, rate limiter)
  └─▶ MinIO       :9000  (S3-compatible object storage)
```

All four application processes (invenio-ui, invenio-api, celery, minio) are managed by **Supervisor** via `~/invenio-supervisor.conf`.

---

## Key Paths

| Purpose | Path |
|---|---|
| Project root | `~/invenio-rdm/` |
| Python virtualenv | `~/invenio-venv/` |
| Instance config & assets | `~/invenio-instance/` (`$INVENIO_INSTANCE_PATH`) |
| Supervisor config | `~/invenio-supervisor.conf` |

The `INVENIO_INSTANCE_PATH` environment variable **must** be set before running any `invenio` CLI command or starting the app.

---

## Setup & Running

### Prerequisites
- Python 3.9 exactly (not 3.10+)
- Node.js 18 + `lessc` + `cleancss` (global npm packages)
- All infrastructure services running (PostgreSQL 14, Redis 7, OpenSearch 2, RabbitMQ 3, MinIO)

### One-time initialisation (run once after services are up)
```bash
source ~/invenio-venv/bin/activate
export INVENIO_INSTANCE_PATH=~/invenio-instance
bash ~/invenio-rdm/scripts/setup.sh
```

### Start / stop the application
```bash
source ~/invenio-venv/bin/activate
supervisord -c ~/invenio-supervisor.conf          # start all processes
supervisorctl -c ~/invenio-supervisor.conf status  # check status
supervisorctl -c ~/invenio-supervisor.conf shutdown # stop all
```

### Restart a single process
```bash
supervisorctl -c ~/invenio-supervisor.conf restart invenio-api
```

### Tail logs
```bash
tail -f /tmp/invenio-ui.log
tail -f /tmp/invenio-api.log
tail -f /tmp/celery.log
```

### Smoke test
```bash
curl -s http://localhost/api/records | python3 -m json.tool | head -15
```

---

## Ingest & API Scripts

### Ingest the Iris dataset
```bash
source ~/invenio-venv/bin/activate
export INVENIO_INSTANCE_PATH=~/invenio-instance

python ~/invenio-rdm/scripts/ingest.py \
    --token <YOUR_TOKEN_HERE> \
    --base-url http://localhost:5001 \
    --no-api-prefix
```

> **Why `--base-url http://localhost:5001 --no-api-prefix`?**  
> `ingest.py` calls the API server directly (bypassing nginx). The API app registers routes at `/records` — not `/api/records`. nginx strips the `/api` prefix before forwarding, so `--no-api-prefix` must be passed when calling port 5001 directly.

### Preview API output
```bash
python ~/invenio-rdm/scripts/api_preview.py
```

---

## Key Conventions & Gotchas

- **`invenio-s3` must be `>=1.0.0,<2.0.0`** — v2.x requires `invenio-files-rest>=3.0` which conflicts with InvenioRDM v12.
- **OpenSearch security plugin is disabled** in this PoC (`plugins.security.disabled: true` in `/etc/opensearch/opensearch.yml`). Re-enable with TLS for production.
- **Frontend rebuild** is required after any asset/template change:
  ```bash
  invenio webpack buildall
  ```
- **`assets/less/theme.config`** must exist at `$INVENIO_INSTANCE_PATH/assets/less/theme.config` before running `invenio webpack buildall` — the build fails silently without it.
- **Admin user confirmation** must be done programmatically (email is disabled): the setup script handles this via `invenio shell`. The default admin is `admin@example.com / Admin1234!`.
- **API token** must be generated at `http://localhost/account/settings/applications/tokens/new/` before running `ingest.py`.
- **Redis databases**: cache/sessions → db 0, Celery results → db 2, rate limiter → db 3.

---

## Quick Reference

| What | URL / Command |
|---|---|
| Repository UI | http://localhost |
| REST API | http://localhost/api/records |
| Admin login | admin@example.com / Admin1234! |
| MinIO console | http://localhost:9001 (minio / minio123456) |
| RabbitMQ management | http://localhost:15672 (guest / guest) |
| OpenSearch health | `curl http://localhost:9200/_cluster/health` |
