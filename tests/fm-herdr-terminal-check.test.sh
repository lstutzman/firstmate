#!/usr/bin/env bash
# Stubbed-herdr test for bin/fm-herdr-terminal-check.sh label matching: plain
# and "[n] "-prefixed Terminal labels both count; lookalikes do not.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v jq >/dev/null 2>&1 || { echo 'skip: jq not found'; exit 0; }
TMP=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-terminal-check.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/home/state" "$TMP/home/config"
echo herdr > "$TMP/home/config/backend"
cat > "$TMP/bin/herdr" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"workspace list"*) cat "$STUB_DIR/workspaces.json" ;;
  *"agent list"*) echo '{"result":{"agents":[]}}' ;;
  *"workspace create"*) echo create >> "$STUB_DIR/calls"; echo '{"result":{"workspace":{"workspace_id":"wNEW"}}}' ;;
esac
SH
chmod +x "$TMP/bin/herdr"
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
run() { # <label>... -> output; sets creates
  local i=0 sep=
  printf '{"result":{"workspaces":[' > "$TMP/workspaces.json"
  for l in "$@"; do
    i=$((i + 1))
    printf '%s{"workspace_id":"w%s","label":"%s","tab_count":1,"pane_count":1}' "$sep" "$i" "$l" >> "$TMP/workspaces.json"
    sep=,
  done
  printf ']}}' >> "$TMP/workspaces.json"
  rm -f "$TMP/calls"
  OUT=$(STUB_DIR=$TMP FM_HOME="$TMP/home" FM_BACKEND=herdr HERDR_SESSION=stub \
    FM_HERDR_TERMINAL_LOCK="$TMP/lock" PATH="$TMP/bin:$PATH" "$ROOT/bin/fm-herdr-terminal-check.sh")
  CREATES=0; [ -f "$TMP/calls" ] && CREATES=$(wc -l < "$TMP/calls")
}
for l in Terminal '[5] Terminal'; do
  run other "$l"
  [ "$CREATES" -eq 0 ] && [ -z "$OUT" ] || fail "'$l' not recognised: creates=$CREATES out=$OUT"
  echo "ok - '$l' is found and not recreated"
done
run other 'Terminal' '[5] Terminal'
case "$OUT" in *"2 workspaces are labelled"*) ;; *) fail "two Terminals not counted: $OUT" ;; esac
echo "ok - plain and prefixed Terminal count as two"
for l in 'Terminal 2' '[5] Terminals' 'My Terminal' '[x] Terminal'; do
  run "$l"
  [ "$CREATES" -eq 1 ] || fail "'$l' wrongly matched as Terminal"
  echo "ok - '$l' is not a match"
done
printf '{"result":{"workspaces":[{"workspace_id":"w1","label":null,"tab_count":1,"pane_count":1},{"workspace_id":"w2","tab_count":1,"pane_count":1},{"workspace_id":"w3","label":"[5] Terminal","tab_count":1,"pane_count":1}]}}' > "$TMP/workspaces.json"
rm -f "$TMP/calls"
OUT=$(STUB_DIR=$TMP FM_HOME="$TMP/home" FM_BACKEND=herdr HERDR_SESSION=stub \
  FM_HERDR_TERMINAL_LOCK="$TMP/lock" PATH="$TMP/bin:$PATH" "$ROOT/bin/fm-herdr-terminal-check.sh" 2>&1)
[ ! -f "$TMP/calls" ] && [ -z "$OUT" ] || fail "null or missing label broke the Terminal match: out=$OUT"
echo "ok - null and missing labels beside a Terminal leave it found and not recreated"
