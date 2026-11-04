#!/usr/bin/env bash
# Adversarial live scenario: a real Herdr ship spawn whose project origin is
# unreachable after the slot is leased and the pane exists, so the spawn aborts
# before its task record is published. Records the pane, the lease, and meta.
set -u
ROOT={run-worktree}
. "$ROOT/tests/herdr-test-safety.sh"; herdr_forget_inherited_pane
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-abort-lease.XXXXXX")
SESSION=$(fm_herdr_lab_name rcabort); export HERDR_SESSION="$SESSION"
cleanup() { herdr_safe_stop_and_delete "$SESSION" >/dev/null 2>&1; find "$TMP_ROOT" -type d -exec chmod u+rwx {} + 2>/dev/null; /usr/bin/trash "$TMP_ROOT"; }
trap cleanup EXIT
fm_herdr_lab_prepare "$SESSION" || exit 1
H="$TMP_ROOT/home"; mkdir -p "$H/state" "$H/data/rc1" "$H/config" "$H/projects"
printf 'off\n' > "$H/config/herdr-presentation-spaces"
printf '# Task\n## Captain'"'"'s intent\nlab\n\n## Firstmate spec\nlab\n' > "$H/data/rc1/brief.md"
PROJ="$H/projects/scratch"; mkdir -p "$PROJ"; git -C "$PROJ" init -q
printf '# s\n' > "$PROJ/README.md"; git -C "$PROJ" add README.md; git -C "$PROJ" -c user.name=t -c user.email=t@example.invalid commit -qm i
git clone -q --bare "$PROJ" "$TMP_ROOT/origin.git"; git -C "$PROJ" remote add origin "file://$TMP_ROOT/origin.git"
# Fault injection: wrap the REAL treehouse so the origin disappears right after a
# successful `get`, making the spawn's later base refresh fail after the lease.
mkdir -p "$TMP_ROOT/bin"; REAL_TH=$(command -v treehouse)
cat > "$TMP_ROOT/bin/treehouse" <<EOF
#!/usr/bin/env bash
"$REAL_TH" "\$@"; rc=\$?
[ "\$1" = get ] && [ \$rc -eq 0 ] && mv "$TMP_ROOT/origin.git" "$TMP_ROOT/origin.gone"
exit \$rc
EOF
chmod +x "$TMP_ROOT/bin/treehouse"; export PATH="$TMP_ROOT/bin:$PATH"
FM_SPAWN_NO_GUARD=1 FM_HOME="$H" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-spawn.sh" rc1 "$PROJ" \
  "sh -c 'echo crew-ok; exec sleep 900'" --mode no-mistakes --yolo off --backend herdr >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"
echo "spawn exit=$?"; echo "-- spawn stderr (tail)"; tail -6 "$TMP_ROOT/err"
echo "-- task record present: $([ -e "$H/state/rc1.meta" ] && echo yes || echo no)"
echo "-- panes in lab session (raw):"; herdr pane list --session "$SESSION" 2>&1 | jq -c "[.result.panes[]? | {pane_id, cwd}]"; herdr tab list --session "$SESSION" 2>&1 | jq -c "[.result.tabs[]? | {tab_id,label}]"
POOL=$(grep -l -F "$PROJ" ~/.treehouse/scratch-*/treehouse-state.json 2>/dev/null | head -1)
echo "-- treehouse state for this project ($POOL):"; [ -n "$POOL" ] && jq -c . "$POOL"
echo "-- pool dir: $(dirname "$POOL")"
