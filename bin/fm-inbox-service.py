#!/usr/bin/env python3
"""Validate and render machine-service inbox bodies; never read evidence files.

Usage: fm-inbox-service.py validate|request-id|wake|relay < record.json
The record schema is owned by docs/configuration.md (Machine-service intake).
Invalid records exit 1 with a field diagnostic, never the supplied value.
"""

import hashlib
import json
import re
import sys


def unique_fields(pairs):
    result = {}
    for name, value in pairs:
        if name in result:
            raise ValueError("duplicate field")
        result[name] = value
    return result


def read_record():
    raw = sys.stdin.read(8193)
    if len(raw) > 8192:
        raise ValueError("record exceeds 8192 characters")
    record = json.loads(raw, object_pairs_hook=unique_fields)
    required = {"kind", "source", "item_id", "severity", "evidence_path", "request_id"}
    if not isinstance(record, dict) or not required <= record.keys():
        raise ValueError("missing required fields")
    if record.keys() - required - {"key"}:
        raise ValueError("unknown fields")
    if any(not isinstance(value, str) for value in record.values()):
        raise ValueError("fields must be strings")
    if record["kind"] not in {"dispatch", "notice", "blocked"}:
        raise ValueError("invalid kind")
    if record["severity"] not in {"info", "low", "medium", "high", "critical"}:
        raise ValueError("invalid severity")
    for name in ("source", "item_id", "request_id", "key"):
        if name in record and not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,95}", record[name]):
            raise ValueError("invalid " + name)
    path = record["evidence_path"]
    if not path.startswith("/") or len(path) > 1024 or any(ord(c) < 32 or ord(c) > 126 for c in path):
        raise ValueError("invalid evidence_path")
    return record


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in {"validate", "request-id", "wake", "relay"}:
        raise ValueError("expected validate, request-id, wake, or relay")
    record = read_record()
    command = sys.argv[1]
    if command == "validate":
        print(json.dumps(record, sort_keys=True, separators=(",", ":")))
    elif command == "request-id":
        print("service:" + record["request_id"])
    elif command == "wake":
        print("check: machine service {kind} {item_id} request={request_id}".format(**record))
    else:
        if record["kind"] == "dispatch":
            return
        key = record.get("key") or hashlib.sha256(record["request_id"].encode()).hexdigest()[:24]
        verb = "blocked" if record["kind"] == "blocked" else "working"
        print(f"{verb} [key=machine-{key}]: machine service {record['kind']} "
              f"source={record['source']} item={record['item_id']} severity={record['severity']} "
              f"request={record['request_id']} evidence={record['evidence_path']}")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError) as error:
        # JSON decoder diagnostics can include untrusted source text.
        message = "invalid JSON" if isinstance(error, json.JSONDecodeError) else str(error)
        print("fm-inbox service: " + message, file=sys.stderr)
        sys.exit(1)
