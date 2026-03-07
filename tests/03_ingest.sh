#!/usr/bin/env bash
# tests/03_ingest.sh — Validate the Iris dataset files and checksums.
# Run before/after ingest.py to confirm dataset integrity.
#
# Usage:  bash tests/03_ingest.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DATASET_DIR="$SCRIPT_DIR/../invenio-rdm/datasets/iris"
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

echo ""
echo "=== Dataset Integrity Checks ==="
echo ""

echo "--- Required files present ---"
for f in data.csv schema.json metadata.json README.md; do
    check "datasets/iris/$f exists" test -f "$DATASET_DIR/$f"
done

echo ""
echo "--- data.csv structure ---"
check "data.csv has header row" grep -q "sepal_length,sepal_width,petal_length,petal_width,species" "$DATASET_DIR/data.csv"
check "data.csv has 150 data rows" bash -c "[ \$(tail -n +2 '$DATASET_DIR/data.csv' | wc -l | tr -d ' ') -eq 150 ]"
check "data.csv contains setosa"    grep -q "setosa"    "$DATASET_DIR/data.csv"
check "data.csv contains versicolor" grep -q "versicolor" "$DATASET_DIR/data.csv"
check "data.csv contains virginica"  grep -q "virginica"  "$DATASET_DIR/data.csv"

echo ""
echo "--- metadata.json structure ---"
check "metadata.json is valid JSON" python3 -c "import json; json.load(open('$DATASET_DIR/metadata.json'))"
check "metadata.json has title"     python3 -c "import json; d=json.load(open('$DATASET_DIR/metadata.json')); assert d['metadata']['title']"
check "metadata.json has access"    python3 -c "import json; d=json.load(open('$DATASET_DIR/metadata.json')); assert d['access']['record'] == 'public'"
check "metadata.json has creators"  python3 -c "import json; d=json.load(open('$DATASET_DIR/metadata.json')); assert len(d['metadata']['creators']) >= 1"

echo ""
echo "--- schema.json structure ---"
check "schema.json is valid JSON" python3 -c "import json; json.load(open('$DATASET_DIR/schema.json'))"
check "schema.json has 5 properties" python3 -c "import json; d=json.load(open('$DATASET_DIR/schema.json')); assert len(d['properties']) == 5"

echo ""
echo "--- checksums.txt (if present) ---"
if [ -f "$DATASET_DIR/checksums.txt" ]; then
    check "checksums.txt format valid" grep -qE "^sha256:[a-f0-9]{64}  " "$DATASET_DIR/checksums.txt"
    echo "  [INFO] checksums.txt found — run 'sha256sum -c $DATASET_DIR/checksums.txt' to verify"
else
    echo "  [INFO] checksums.txt not yet generated (run ingest.py first)"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && echo "Dataset looks good." || { echo "Dataset has issues — fix before ingesting."; exit 1; }
