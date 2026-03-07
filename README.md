# InvenioRDM PoC — Native Ubuntu 22.04 Setup

```
copilot --resume=b498e773-127f-4b79-818e-dbc1743bb496
```

```
Use your VM’s host IP (e.g., from hostname -I), then: UI via http://<VM-IP> (nginx :80), REST via
  http://<VM-IP>/api/records, MinIO console http://<VM-IP>:9001 (S3 API :9000), RabbitMQ http://
  <VM-IP>:15672, OpenSearch http://<VM-IP>:9200. The uWSGI apps listen on 5000 (UI) and 5001 (API)
  but are normally behind nginx; expose 80 (and the consoles) in your firewall/security group. If
  you need to hit the API app directly, use http://<VM-IP>:5001/records (no /api prefix)
```

Self-hosted research data repository running **InvenioRDM v12** natively on Ubuntu 22.04. No Docker — all services run as native OS daemons.

## Quick start (Ubuntu 22.04 VM)

```bash
git clone https://github.com/edgar-treischl/Invenio.git ~/invenio-repo
cd ~/invenio-repo
bash deploy.sh
```

`deploy.sh` installs all system dependencies, infrastructure services, Python packages, wires up nginx and supervisord, and runs the one-time setup — fully automated.

## Manual step-by-step

See [`outline.md`](outline.md) for the complete annotated guide.

## Test strategy

| Script | When to run | What it checks |
|--------|-------------|----------------|
| `tests/01_services.sh` | Before `setup.sh` | All infrastructure ports + HTTP health endpoints |
| `tests/02_app.sh` | After `supervisord` starts | uWSGI processes, nginx proxy, API response shape |
| `tests/03_ingest.sh` | Before/after `ingest.py` | Dataset file integrity, CSV row count, JSON validity |
| `tests/04_api_record.sh` | After `ingest.py` | Record metadata, file listings, search index |

Run all tests:
```bash
make test-all
```

Run a single suite:
```bash
bash tests/01_services.sh
bash tests/02_app.sh
bash tests/03_ingest.sh
bash tests/04_api_record.sh [optional-record-id]
```

## Ingest the Iris dataset

1. Create a personal API token at `http://localhost/account/settings/applications/tokens/new/`
2. Run:
   ```bash
   source ~/invenio-venv/bin/activate
   export INVENIO_INSTANCE_PATH=~/invenio-instance
   python invenio-rdm/scripts/ingest.py \
       --token <YOUR_TOKEN> \
       --base-url http://localhost:5001 \
       --no-api-prefix
   ```

## Repository layout

```
.
├── deploy.sh                  ← One-command deploy for Ubuntu 22.04
├── Makefile                   ← Convenience targets (deploy, test-*, logs, restart)
├── invenio-supervisor.conf    ← Supervisor process manager config
├── nginx/
│   └── invenio.conf           ← Nginx virtual host (symlinked to sites-enabled)
├── invenio-rdm/               ← Application source (copied to ~/invenio-rdm on deploy)
│   ├── requirements.txt
│   ├── src/
│   │   ├── wsgi_ui.py
│   │   └── wsgi_rest.py
│   ├── scripts/
│   │   ├── setup.sh           ← One-time initialisation
│   │   ├── ingest.py          ← Upload Iris dataset via API
│   │   └── api_preview.py     ← Preview ingested record
│   └── datasets/iris/
│       ├── data.csv
│       ├── schema.json
│       ├── metadata.json
│       └── README.md
├── invenio-instance/          ← Instance config (copied to ~/invenio-instance on deploy)
│   ├── invenio.cfg
│   ├── uwsgi_ui.ini
│   ├── uwsgi_rest.ini
│   └── assets/less/theme.config
└── tests/
    ├── 01_services.sh
    ├── 02_app.sh
    ├── 03_ingest.sh
    └── 04_api_record.sh
```

## Quick reference

| What | URL / Command |
|---|---|
| Repository UI | http://localhost |
| REST API | http://localhost/api/records |
| Admin login | admin@example.com / Admin1234! |
| MinIO console | http://localhost:9001 (minio / minio123456) |
| Supervisor status | `supervisorctl -c ~/invenio-supervisor.conf status` |
| UI log | `tail -f /tmp/invenio-ui.log` |
| API log | `tail -f /tmp/invenio-api.log` |
| Celery log | `tail -f /tmp/celery.log` |
