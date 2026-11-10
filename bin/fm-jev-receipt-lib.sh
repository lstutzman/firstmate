#!/usr/bin/env bash
# fm-jev-receipt-lib.sh - the bash side of the local-jev receipt writer.
#
# fm_jev_receipt <call|decision|outcome> <fields-json>
#   Appends one local-jev-receipt.v1 record through bin/fm-jev-receipts.py,
#   which owns the stream location, the shared fields, and the append-only
#   write, and prints the record's receipt_id on stdout (nothing when it was
#   not written). It always returns 0: a missing python3 or a failed write
#   prints one "local-jev receipt: not written (...)" warning on stderr and the
#   caller carries on unchanged. docs/local-jev-receipts.md owns the schema.

case "${BASH_SOURCE[0]}" in */*) FM_JEV_RECEIPT_LIB_DIR=${BASH_SOURCE[0]%/*} ;; *) FM_JEV_RECEIPT_LIB_DIR=. ;; esac
FM_JEV_RECEIPT_LIB_DIR=$(cd "$FM_JEV_RECEIPT_LIB_DIR" && pwd)

fm_jev_receipt() {
  local py
  py=$(command -v python3 2>/dev/null) \
    || { echo "local-jev receipt: not written (python3 not found)" >&2; return 0; }
  "$py" -I "$FM_JEV_RECEIPT_LIB_DIR/fm-jev-receipts.py" append "$1" <<<"$2" || true
  return 0
}
