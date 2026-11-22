#!/usr/bin/env bash
# fm-instruction-size-check.sh - hold each always-loaded instruction file under a byte ceiling.
#
# Usage:
#   bin/fm-instruction-size-check.sh [--root <repo>] [--pins <file>]
#
# docs/instruction-size-pins.json maps a repo-relative path to its byte ceiling.
# A file above its pin fails: every session pays for those bytes.
# A file 512 or more bytes under its pin also fails, so the pin comes down with the file.
# A pinned file that is missing fails.
# Raise a pin only in the PR that justifies the growth; move conditional detail to a skill or doc first.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PINS=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root) ROOT="$2"; shift 2 ;;
    --pins) PINS="$2"; shift 2 ;;
    *) echo "usage: fm-instruction-size-check.sh [--root <repo>] [--pins <file>]" >&2; exit 2 ;;
  esac
done
[ -n "$PINS" ] || PINS="$ROOT/docs/instruction-size-pins.json"
[ -f "$PINS" ] || { echo "fm-instruction-size-check: missing pins file $PINS" >&2; exit 1; }

exec python3 -I - "$ROOT" "$PINS" <<'PY'
import json
import sys
from pathlib import Path

root, pins_path = Path(sys.argv[1]), Path(sys.argv[2])
pins = json.loads(pins_path.read_text(encoding="utf-8"))
slack = 512
failures = []
for rel, ceiling in sorted(pins.items()):
    target = root / rel
    if not target.is_file():
        failures.append(f"{rel}: pinned but missing")
        continue
    size = target.stat().st_size
    if size > ceiling:
        failures.append(f"{rel}: {size} bytes is over its pin of {ceiling}; move conditional detail to a skill or doc")
    elif ceiling - size >= slack:
        failures.append(f"{rel}: {size} bytes is {ceiling - size} under its pin of {ceiling}; lower the pin to {size}")
if failures:
    for line in failures:
        print(f"fm-instruction-size-check: {line}", file=sys.stderr)
    sys.exit(1)
print(f"fm-instruction-size-check: ok files={len(pins)}")
PY
