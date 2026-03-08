#!/usr/bin/env bash
# setup.sh — One-time initialisation of an InvenioRDM instance (native / no Docker).
# Usage: bash ~/invenio-rdm/scripts/setup.sh
set -euo pipefail

# ── Configurable environment variables ───────────────────────────────────────
ADMIN_EMAIL="${INVENIO_ADMIN_EMAIL:-admin@example.com}"
ADMIN_PASSWORD="${INVENIO_ADMIN_PASSWORD:-Admin1234!}"
MINIO_ENDPOINT="${INVENIO_S3_ENDPOINT_URL:-http://localhost:9000}"
MINIO_USER="${INVENIO_S3_ACCESS_KEY_ID:-minio}"
MINIO_PASS="${INVENIO_S3_SECRET_ACCESS_KEY:-minio123456}"
BUCKET_NAME="default"

# Export credentials for boto3 / Invenio
export INVENIO_S3_ACCESS_KEY_ID="$MINIO_USER"
export INVENIO_S3_SECRET_ACCESS_KEY="$MINIO_PASS"
export INVENIO_S3_ENDPOINT_URL="$MINIO_ENDPOINT"

log() { echo "[setup] $*"; }

wait_for() {
    local host=$1 port=$2
    log "Waiting for $host:$port …"
    until nc -z "$host" "$port" 2>/dev/null; do sleep 3; done
    log "$host:$port is up."
}

# Wait for OpenSearch cluster health to reach at least yellow.
wait_for_opensearch() {
    local url=${1:-http://localhost:9200/_cluster/health}
    log "Waiting for OpenSearch cluster health …"
    for i in $(seq 1 30); do
        status=$(curl -s --max-time 5 "$url" | python3 -c 'import sys, json; data=sys.stdin.read(); print(json.loads(data).get("status","") if data else "")')
        if [[ "$status" == "yellow" || "$status" == "green" ]]; then
            log "OpenSearch health is $status."
            return 0
        fi
        sleep 2
    done
    log "ERROR: OpenSearch did not become ready in time."
    return 1
}

# ── Wait for services ─────────────────────────────────────────────────────────
wait_for localhost 5432  # PostgreSQL
wait_for localhost 9200  # OpenSearch
wait_for localhost 6379  # Redis
wait_for localhost 5672  # RabbitMQ
wait_for localhost 9000  # MinIO
# Ensure OpenSearch responds before proceeding
wait_for_opensearch

# ── Give MinIO a moment to fully initialize ───────────────────────────────────
sleep 5

# ── MinIO bucket ──────────────────────────────────────────────────────────────
log "Creating MinIO bucket '$BUCKET_NAME' …"
python3 - <<PYEOF
import boto3
from botocore.exceptions import ClientError
import os

s3 = boto3.client(
    "s3",
    endpoint_url=os.environ["INVENIO_S3_ENDPOINT_URL"],
    aws_access_key_id=os.environ["INVENIO_S3_ACCESS_KEY_ID"],
    aws_secret_access_key=os.environ["INVENIO_S3_SECRET_ACCESS_KEY"],
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
    log "       Copy it from the repo: cp ~/invenio-rdm/invenio-instance/assets/less/theme.config ${ASSETS}/less/"
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
