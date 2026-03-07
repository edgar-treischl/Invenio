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
