# shellcheck shell=bash
# Shared .env-style file accessor and typesafe base URL resolution.
# Usage: . bin/fm-env-lib.sh
#
# This file is the single owner of the one-key .env read: the Relay pairing
# token (bin/fm-x-lib.sh and its callers) and the optional typesafe.ai
# dispatch key (bin/fm-dispatch-resolve.sh) both resolve their value through
# fmx_env_get, so those opt-in secrets in $FM_HOME/.env are parsed by one rule.
# (bin/fm-mail.sh loads its whole .env block itself under the same env-wins
# contract.) The value is printed to the caller's command substitution only;
# nothing is logged.

# fmx_env_get <key> <file>
# Read the value of KEY from a .env-style file: last assignment wins; tolerates a
# leading "export ", surrounding whitespace, and one layer of matching single or
# double quotes. Prints nothing (and succeeds) when the file or key is absent, so
# callers can treat empty output as "unset".
fmx_env_get() {
  local key=$1 file=$2 line val
  [ -f "$file" ] || return 0
  line=$(grep -E "^[[:space:]]*(export[[:space:]]+)?${key}=" "$file" 2>/dev/null | tail -n1) || return 0
  [ -n "$line" ] || return 0
  val=${line#*=}
  val=${val#"${val%%[![:space:]]*}"}   # strip leading whitespace
  val=${val%"${val##*[![:space:]]}"}   # strip trailing whitespace (incl. CR)
  case "$val" in
    \"*\") val=${val#\"}; val=${val%\"} ;;
    \'*\') val=${val#\'}; val=${val%\'} ;;
  esac
  printf '%s' "$val"
}

FM_TYPESAFE_DEFAULT_BASE=https://api.typesafe.ai

# fm_typesafe_config_line <config-dir> <name>
# Print the first non-blank, non-# line of <config-dir>/<name>, trimmed; nothing
# when the file is absent, unreadable, or has no such line.
fm_typesafe_config_line() {
  [ -r "$1/$2" ] || return 0
  awk '/^[[:space:]]*(#|$)/ { next } { sub(/^[[:space:]]+/, ""); sub(/[[:space:]]+$/, ""); print; exit }' "$1/$2"
}

# fm_typesafe_base_url <config-dir>
# Resolve the typesafe base URL for the dispatch resolver: TYPESAFE_BASE_URL in
# the environment, else the first non-blank, non-# line of
# <config-dir>/typesafe-base-url, else FM_TYPESAFE_DEFAULT_BASE. Accepts only
# http:// or https:// URLs with a host and no whitespace; trailing slashes are
# trimmed. Prints the URL and succeeds, or prints the reason and returns 1.
# bin/fm-dispatch-resolve.sh and bin/fm-bootstrap.sh both resolve through here,
# so a non-default result turns the resolver on in both by the same rule.
fm_typesafe_base_url() {
  local config=$1 url=${TYPESAFE_BASE_URL:-}
  [ -n "$url" ] || url=$(fm_typesafe_config_line "$config" typesafe-base-url)
  if [ -z "$url" ]; then
    printf '%s' "$FM_TYPESAFE_DEFAULT_BASE"
    return 0
  fi
  case "$url" in
    http://?*|https://?*) ;;
    *) printf 'typesafe base URL must be an http:// or https:// URL: %s' "$url"; return 1 ;;
  esac
  case "$url" in
    *[[:space:]]*) printf 'typesafe base URL must not contain whitespace: %s' "$url"; return 1 ;;
  esac
  while [ "${url%/}" != "$url" ]; do url=${url%/}; done
  case "$url" in
    http://|https://) printf 'typesafe base URL has no host: %s' "$url"; return 1 ;;
  esac
  printf '%s' "$url"
}

# fm_typesafe_token <config-dir>
# Read the local Jev bearer token from the file whose path is the first line of
# <config-dir>/typesafe-token-file (a leading ~/ expands to HOME). Prints the
# token and succeeds; prints nothing and succeeds when no token file is
# configured; prints the reason, never the contents, and returns 1 when the
# configured file is unreadable or empty.
fm_typesafe_token() {
  local path token
  path=$(fm_typesafe_config_line "$1" typesafe-token-file)
  [ -n "$path" ] || return 0
  case "$path" in
    "~/"*) path=$HOME/${path#"~/"} ;;
  esac
  if [ ! -f "$path" ] || [ ! -r "$path" ]; then
    printf 'typesafe token file is not a readable file: %s' "$path"
    return 1
  fi
  token=$(tr -d '\r\n' < "$path")
  if [ -z "$token" ]; then
    printf 'typesafe token file is empty: %s' "$path"
    return 1
  fi
  printf '%s' "$token"
}
