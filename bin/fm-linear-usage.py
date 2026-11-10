#!/usr/bin/env python3
"""fm-linear-usage.py - best-effort per-call Linear usage records (shared contract).

Library use (loaded by file path, like the other bin/ python helpers):
    usage = load("fm-linear-usage.py"); usage.record(job=..., caller=..., op=..., status=..., headers=...)

Each Linear HTTP call appends one JSON line to ~/.local/state/linear-usage/usage.jsonl
(directory 0700, file 0600) with: ts, host, job, caller, op, status, requests_limit,
requests_remaining, complexity_limit, complexity_remaining, complexity, key, retry_after.
Missing values are null. `key` is the credential's NAME only; no key value, hash, request
body or response body is ever written. A host other than slartibartfast also POSTs the
same object to the fleet app's /api/linear-usage with a 2-second timeout and no retry.
FM_LINEAR_USAGE_DIR relocates the sink (tests). Logging never raises and never fails the Linear call. LINEAR_JOB overrides the job name.
"""
import datetime
import json
import os
import socket
import urllib.request

INGEST = "https://slartibartfast.tail299042.ts.net:8743/api/linear-usage"
SINK_HOST = "slartibartfast"
HEADERS = (("requests_limit", "X-RateLimit-Requests-Limit"),
           ("requests_remaining", "X-RateLimit-Requests-Remaining"),
           ("complexity_limit", "X-RateLimit-Complexity-Limit"),
           ("complexity_remaining", "X-RateLimit-Complexity-Remaining"),
           ("complexity", "X-Complexity"))


def job_name(default):
    return os.environ.get("LINEAR_JOB") or default


def _number(value):
    try:
        return float(value) if "." in str(value) else int(value)
    except (TypeError, ValueError):
        return None


def build(job, caller, op, status, headers, key, host=None):
    lowered = {str(k).lower(): v for k, v in dict(headers or {}).items()}
    row = {"ts": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
           "host": host or socket.gethostname().split(".")[0],
           "job": job_name(job), "caller": caller, "op": op or "unknown", "status": status}
    for field, header in HEADERS:
        row[field] = _number(lowered.get(header.lower()))
    row["key"] = key
    row["retry_after"] = _number(lowered.get("retry-after"))
    return row


def record(job, caller, op=None, status=None, headers=None, key=None, state_dir=None, post=True):
    """Append one usage line; returns the row, or None when logging failed. Never raises."""
    try:
        row = build(job, caller, op, status, headers, key)
        base = state_dir or os.environ.get("FM_LINEAR_USAGE_DIR") or os.path.join(os.path.expanduser("~"), ".local", "state", "linear-usage")
        os.makedirs(base, mode=0o700, exist_ok=True)
        fd = os.open(os.path.join(base, "usage.jsonl"), os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
        with os.fdopen(fd, "a") as fh:
            fh.write(json.dumps(row, separators=(",", ":")) + "\n")
        if post and row["host"] != SINK_HOST and not os.environ.get("FM_LINEAR_USAGE_NO_POST"):
            try:
                req = urllib.request.Request(os.environ.get("FM_LINEAR_USAGE_INGEST", INGEST),
                                             data=json.dumps(row).encode(), method="POST",
                                             headers={"Content-Type": "application/json"})
                urllib.request.urlopen(req, timeout=2).close()
            except Exception:  # noqa: BLE001 - best effort, the local line stays
                pass
        return row
    except Exception:  # noqa: BLE001 - logging never fails the Linear call
        return None
