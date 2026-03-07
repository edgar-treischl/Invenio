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


def upload_files(session, base: str, record_id: str, files: list):
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


def write_checksums(files: list):
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
