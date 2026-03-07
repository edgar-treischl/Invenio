#!/usr/bin/env bash
# tests/04_api_record.sh — Verify an ingested record is accessible via the API.
# Run after ingest.py has been executed successfully.
#
# Usage:  bash tests/04_api_record.sh
#   or:   bash tests/04_api_record.sh <RECORD_ID>
set -euo pipefail

RECORD_ID="${1:-}"
API_BASE="http://localhost:5001"
PASS=0; FAIL=0

check() {
    local name=$1; shift
    if "$@" &>/dev/null; then
        echo "  [PASS] $name"
        PASS=$((PASS+1))
    else
        echo "  [FAIL] $name"
        FAIL=$((FAIL+1))
    fi
}

api_get() {
    curl -sf -H "Host: localhost" "$API_BASE$1"
}

echo ""
echo "=== Ingested Record API Tests ==="
echo ""

# Discover the most recent Iris record if no ID supplied
if [ -z "$RECORD_ID" ]; then
    echo "No record ID supplied — searching for Iris record …"
    RECORD_ID=$(api_get "/records?q=iris&sort=newest&size=1" \
        | python3 -c "import sys,json; hits=json.load(sys.stdin)['hits']['hits']; print(hits[0]['id'] if hits else '')" 2>/dev/null || echo "")
fi

if [ -z "$RECORD_ID" ]; then
    echo "  [FAIL] No Iris record found. Run ingest.py first."
    exit 1
fi
echo "  Testing record: $RECORD_ID"
echo ""

echo "--- Record metadata ---"
check "Record is publicly accessible" api_get "/records/$RECORD_ID"
check "Record has title" bash -c "api_get '/records/$RECORD_ID' | python3 -c \"import sys,json; d=json.load(sys.stdin); assert d['metadata']['title']\""
check "Record has files enabled" bash -c "api_get '/records/$RECORD_ID' | python3 -c \"import sys,json; d=json.load(sys.stdin); assert d['files']['enabled']\""

echo ""
echo "--- File listings ---"
check "Files endpoint returns entries"  bash -c "api_get '/records/$RECORD_ID/files' | python3 -c \"import sys,json; d=json.load(sys.stdin); assert len(d['entries']) > 0\""
check "data.csv is present in files"    bash -c "api_get '/records/$RECORD_ID/files' | python3 -c \"import sys,json; d=json.load(sys.stdin); assert any(e['key']=='data.csv' for e in d['entries'])\""
check "schema.json is present in files" bash -c "api_get '/records/$RECORD_ID/files' | python3 -c \"import sys,json; d=json.load(sys.stdin); assert any(e['key']=='schema.json' for e in d['entries'])\""
check "README.md is present in files"   bash -c "api_get '/records/$RECORD_ID/files' | python3 -c \"import sys,json; d=json.load(sys.stdin); assert any(e['key']=='README.md' for e in d['entries'])\""

echo ""
echo "--- Search index ---"
check "Record appears in search results" bash -c "api_get '/records?q=iris' | python3 -c \"import sys,json; d=json.load(sys.stdin); assert d['hits']['total'] >= 1\""

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && echo "Record is fully accessible via API." || { echo "One or more checks failed."; exit 1; }
