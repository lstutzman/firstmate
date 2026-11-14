#!/usr/bin/env bash
# fm-gate-files-lib.sh - the gate-file list shape shared by bin/fm-gate-grant.sh
# (the grant record) and bin/fm-brief.sh (--gate-files), so a brief never names
# a list the grant script would refuse.

# A non-empty comma list of plain repo-relative paths: no empty entry, no
# absolute path, no '.' or '..' segment, no doubled or trailing slash, and only
# letters, digits and ._/@+- in each entry.
fm_gate_files_valid() { # <comma list>
  local list=$1 f rest
  [ -n "$list" ] || return 1
  case "$list" in ,* | *, | *,,*) return 1 ;; esac
  rest=$list
  while [ -n "$rest" ]; do
    f=${rest%%,*}
    case "$rest" in *,*) rest=${rest#*,} ;; *) rest= ;; esac
    case "$f" in
      '' | /* | ./* | ../* | */../* | */.. | .. | */./* | */. | *//* | */) return 1 ;;
    esac
    case "$f" in *[!A-Za-z0-9._/@+-]*) return 1 ;; esac
  done
}
