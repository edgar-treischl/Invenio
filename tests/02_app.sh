#!/usr/bin/env bash
# tests/02_app.sh — Smoke tests for running InvenioRDM processes.
# Run after supervisord is started.
#
# Usage:  bash tests/02_app.sh
set -euo pipefail

PASS=0; FAIL=0

check_http() {
    local name=$1 url=$2 expect=$3
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" -H "Host: localhost" "$url" 2>/dev/null || echo "000")
    if [ "$code" = "$expect" ]; then
        echo "  [PASS] $name (HTTP $code)"
        PASS=$((PASS+1))
    else
        echo "  [FAIL] $name → HTTP $code (expected $expect)"
        FAIL=$((FAIL+1))
    fi
}

check_json() {
    local name=$1 url=$2 jq_expr=$3 expected=$4
    local result
    result=$(curl -s -H "Host: localhost" "$url" 2>/dev/null | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    # simple key lookup, e.g. 'hits.total'
    keys = '$jq_expr'.split('.')
    v = data
    for k in keys:
        v = v[k]
    print(str(v))
except Exception as e:
    print('ERROR:' + str(e))
" 2>/dev/null || echo "ERROR")
    if echo "$result" | grep -q "$expected"; then
        echo "  [PASS] $name ($jq_expr = $result)"
        PASS=$((PASS+1))
    else
        echo "  [FAIL] $name ($jq_expr = $result, expected ~$expected)"
        FAIL=$((FAIL+1))
    fi
}

echo ""
echo "=== InvenioRDM Application Smoke Tests ==="
echo ""

echo "--- Process ports ---"
check_http "UI process (:5000)"        "http://localhost:5000/"    "200"
check_http "API process (:5001)"       "http://localhost:5001/records" "200"

echo ""
echo "--- Nginx proxy ---"
check_http "UI via nginx (:80)"        "http://localhost/"             "200"
check_http "API via nginx (/api)"      "http://localhost/api/records"  "200"

echo ""
echo "--- API response structure ---"
check_json "Records endpoint returns hits" \
    "http://localhost:5001/records" "hits.total" ""

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && echo "Application is healthy." || { echo "One or more checks failed."; exit 1; }
