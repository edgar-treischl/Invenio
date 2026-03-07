#!/usr/bin/env bash
# tests/01_services.sh — Verify all infrastructure services are reachable.
# Run this BEFORE setup.sh to confirm the environment is ready.
#
# Usage:  bash tests/01_services.sh
set -euo pipefail

PASS=0; FAIL=0

check() {
    local name=$1 host=$2 port=$3
    if nc -z -w3 "$host" "$port" 2>/dev/null; then
        echo "  [PASS] $name ($host:$port)"
        PASS=$((PASS+1))
    else
        echo "  [FAIL] $name ($host:$port) — not reachable"
        FAIL=$((FAIL+1))
    fi
}

check_http() {
    local name=$1 url=$2 expect=$3
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" "$url" 2>/dev/null || echo "000")
    if [ "$code" = "$expect" ]; then
        echo "  [PASS] $name ($url → HTTP $code)"
        PASS=$((PASS+1))
    else
        echo "  [FAIL] $name ($url → HTTP $code, expected $expect)"
        FAIL=$((FAIL+1))
    fi
}

echo ""
echo "=== Infrastructure Service Health Checks ==="
echo ""

echo "--- TCP port checks ---"
check "PostgreSQL"  localhost 5432
check "Redis"       localhost 6379
check "RabbitMQ"    localhost 5672
check "OpenSearch"  localhost 9200
check "MinIO"       localhost 9000
check "MinIO UI"    localhost 9001

echo ""
echo "--- HTTP health endpoints ---"
check_http "OpenSearch cluster" "http://localhost:9200/_cluster/health" "200"
check_http "MinIO health"       "http://localhost:9000/minio/health/live" "200"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && echo "All services are up." || { echo "Fix failing services before running setup.sh"; exit 1; }
