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
