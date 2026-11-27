#!/usr/bin/env bash
# Which Herdr session and launch-agent label one Firstmate code root's remote
# second mates use on this account.
#
# Source this file; it defines functions only. It is the single owner of that
# identity: bin/fm-remote-doctor.sh prepares the service under it, and
# bin/fm-remote-secondmate-control.sh launches, relaunches, and validates
# endpoints under it, so readiness and launch always name the same service.
# bin/fm-spawn.sh validates a remote route's reported session against the
# names this library can produce.
#
# The code root recorded in ~/.firstmate/remote-herdr-owner owns the primary
# fm-remote session and dev.firstmate.herdr.fm-remote label. Before owner
# records existed, the guard path in the primary darwin launch agent was the
# only durable evidence of its root, so it stands in for a missing record. Every
# other code root on the account gets fm-remote-<root-id> and
# dev.firstmate.herdr.fm-remote-<root-id>, recorded in
# ~/.firstmate/remote-herdr-owner-<root-id>, where <root-id> is the first 16
# hex digits of the SHA-256 of the root path.
#
# Opt-in selected session: an account that wants its remote second mates in a
# Herdr session it already runs (for example the user's `default` session, so
# the mates are visible in the Herdr the user watches) writes that session name
# on one line to ~/.firstmate/remote-herdr-session. Absent that file, the
# identity above is exactly as before. A selected session is the user's own
# service: readiness only reads it and never creates, owns, reloads, or stops
# it, and no launch agent or owner record is written for it.
#
# Functions:
#   fm_remote_herdr_identity <fm-root>
#     Sets FM_REMOTE_HERDR_SESSION, FM_REMOTE_HERDR_LABEL,
#     FM_REMOTE_HERDR_OWNER_DIR, FM_REMOTE_HERDR_OWNER_FILE, and
#     FM_REMOTE_HERDR_OWNER_ROOT (the root proven to own the resolved
#     session, empty when unproven), and FM_REMOTE_HERDR_SELECTED (1 when the
#     session comes from the selection file, else 0; LABEL and OWNER_* are then
#     empty). Returns 1 when <fm-root> needs a root-derived identity and no
#     SHA-256 tool resolves, and 2 when the selection file names an unusable
#     session; FM_REMOTE_HERDR_ERROR then says why.
#   fm_remote_herdr_recorded_owner <owner-file>
#     Prints the root recorded in <owner-file>, nothing when it is absent or
#     not a plain file in a plain directory.
#   fm_remote_herdr_session_name_valid <session>
#     Succeeds for fm-remote and fm-remote-<root-id> only.
#   fm_remote_herdr_selectable_session_name <session>
#     Succeeds for a plain session name the selection file may hold: letters,
#     digits, dot, underscore, and dash, at most 64 characters, starting with a
#     letter or digit, and never an fm-remote or fm-remote-* name, because those
#     belong to the code root's own service.

fm_remote_herdr_recorded_owner() { # <owner-file>
  local file=$1 dir owner=
  dir=${file%/*}
  [ -d "$dir" ] && [ ! -L "$dir" ] && [ -f "$file" ] && [ ! -L "$file" ] || return 0
  IFS= read -r owner < "$file" || true
  printf '%s' "$owner"
}

fm_remote_herdr_root_id() { # <fm-root>
  local digest
  if command -v shasum >/dev/null 2>&1; then
    read -r digest _ < <(printf '%s' "$1" | shasum -a 256) || return 1
  elif command -v sha256sum >/dev/null 2>&1; then
    read -r digest _ < <(printf '%s' "$1" | sha256sum) || return 1
  else
    return 1
  fi
  case "$digest" in *[!0-9a-f]*|'') return 1 ;; esac
  [ "${#digest}" -eq 64 ] || return 1
  printf '%s\n' "${digest:0:16}"
}

# Decode the first shell-quoted argument of the stored `exec` command without
# evaluating it. The renderer uses single quotes, with '\'' for apostrophes.
fm_remote_herdr_legacy_guard() { # <plist>
  local command rest part guard=
  command=$(sed -n 's/^[[:space:]]*<string>exec //p' "$1")
  rest=$command
  while [[ "$rest" == "'"* ]]; do
    rest=${rest#\'}
    [[ "$rest" == *"'"* ]] || return 1
    part=${rest%%\'*}
    guard=$guard$part
    rest=${rest#*\'}
    if [[ "$rest" == "\\'"* ]]; then
      guard="$guard'"
      rest=${rest#??}
    else
      [[ "$rest" == ' '* ]] || return 1
      case "$guard" in */bin/fm-remote-herdr-guard.sh) printf '%s' "$guard"; return 0 ;; esac
      return 1
    fi
  done
  return 1
}

fm_remote_herdr_selectable_session_name() { # <session>
  case "$1" in
    ''|-*|.*|_*|*[!A-Za-z0-9._-]*) return 1 ;;
    fm-remote|fm-remote-*) return 1 ;;
  esac
  [ "${#1}" -le 64 ]
}

# Sets FM_REMOTE_HERDR_SELECTED_NAME (empty when no selection file exists).
# Returns 2 with FM_REMOTE_HERDR_ERROR set when the file is not a plain file or
# does not hold exactly one usable name. Both are consumed by the sourcing
# caller, so their assignments read as unused here.
# shellcheck disable=SC2034
fm_remote_herdr_selected_session() {
  local file="${HOME:-}/.firstmate/remote-herdr-session" name="" extra=""
  FM_REMOTE_HERDR_ERROR=
  FM_REMOTE_HERDR_SELECTED_NAME=
  [ -e "$file" ] || [ -L "$file" ] || return 0
  if [ ! -f "$file" ] || [ -L "$file" ] || [ -L "${file%/*}" ]; then
    FM_REMOTE_HERDR_ERROR="$file must be a plain file"
    return 2
  fi
  { IFS= read -r name || true; IFS= read -r extra || true; } < "$file"
  if [ -n "$extra" ] || ! fm_remote_herdr_selectable_session_name "$name"; then
    FM_REMOTE_HERDR_ERROR="$file must hold one plain Herdr session name (not fm-remote or fm-remote-*) on its first line"
    return 2
  fi
  FM_REMOTE_HERDR_SELECTED_NAME=$name
}

# Consumed by the sourcing caller, so its assignments read as unused here.
# shellcheck disable=SC2034
fm_remote_herdr_identity() { # <fm-root>
  local root=$1 owner plist guard id
  FM_REMOTE_HERDR_SELECTED=0
  fm_remote_herdr_selected_session || return 2
  FM_REMOTE_HERDR_OWNER_DIR="${HOME:-}/.firstmate"
  if [ -n "$FM_REMOTE_HERDR_SELECTED_NAME" ]; then
    FM_REMOTE_HERDR_SELECTED=1
    FM_REMOTE_HERDR_SESSION=$FM_REMOTE_HERDR_SELECTED_NAME
    FM_REMOTE_HERDR_LABEL=
    FM_REMOTE_HERDR_OWNER_FILE=
    FM_REMOTE_HERDR_OWNER_ROOT=
    return 0
  fi
  FM_REMOTE_HERDR_SESSION=fm-remote
  FM_REMOTE_HERDR_LABEL=dev.firstmate.herdr.fm-remote
  FM_REMOTE_HERDR_OWNER_FILE="$FM_REMOTE_HERDR_OWNER_DIR/remote-herdr-owner"
  owner=$(fm_remote_herdr_recorded_owner "$FM_REMOTE_HERDR_OWNER_FILE")
  plist="${HOME:-}/Library/LaunchAgents/$FM_REMOTE_HERDR_LABEL.plist"
  if [ -z "$owner" ] && [ -f "$plist" ] && [ ! -L "$plist" ]; then
    case "${FM_REMOTE_JOB_PLATFORM_OVERRIDE:-$(uname -s 2>/dev/null || true)}" in
      Darwin|darwin)
        guard=$(fm_remote_herdr_legacy_guard "$plist" 2>/dev/null || true)
        owner=${guard%/bin/fm-remote-herdr-guard.sh}
        ;;
    esac
  fi
  FM_REMOTE_HERDR_OWNER_ROOT=$owner
  [ -n "$owner" ] && [ "$owner" != "$root" ] || return 0
  id=$(fm_remote_herdr_root_id "$root") || return 1
  FM_REMOTE_HERDR_SESSION="fm-remote-$id"
  FM_REMOTE_HERDR_LABEL="dev.firstmate.herdr.fm-remote-$id"
  FM_REMOTE_HERDR_OWNER_FILE="$FM_REMOTE_HERDR_OWNER_DIR/remote-herdr-owner-$id"
  FM_REMOTE_HERDR_OWNER_ROOT=$(fm_remote_herdr_recorded_owner "$FM_REMOTE_HERDR_OWNER_FILE")
}

fm_remote_herdr_session_name_valid() { # <session>
  local id
  [ "$1" != fm-remote ] || return 0
  case "$1" in fm-remote-*) ;; *) return 1 ;; esac
  id=${1#fm-remote-}
  [ "${#id}" -eq 16 ] || return 1
  case "$id" in *[!0-9a-f]*) return 1 ;; esac
}
