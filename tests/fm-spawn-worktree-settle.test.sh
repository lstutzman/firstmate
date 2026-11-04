#!/usr/bin/env bash
# Regression test for the fm-spawn.sh treehouse-get worktree-detection settle
# loop (bin/fm-spawn.sh, the `for _ in $(seq 1 60)` loop after `treehouse get`).
#
# On some tmux/WSL setups a brand-new window's pane_current_path transiently
# reports a stale, unrelated-but-real path on the very first poll, before the
# pane actually settles into the worktree treehouse get moved it to. That stale
# path still passes the loop's "differs from the project" check and
# validate_spawn_worktree's "is a real, distinct worktree" check (it IS a real
# git checkout, just the wrong one), so a naive single-read loop silently
# records the wrong worktree= in state/<id>.meta. This test simulates that
# transient-then-settled pane_current_path sequence with a fake tmux and
# asserts the recorded worktree resolves to the real, settled worktree, never
# the stale first read.
#
# The same loop has a second transient to survive: `treehouse get` reports the
# REPOSITORY's primary checkout as its own cwd while it is still preparing a
# slot. From a linked spawning home that path is not the project, so a poll
# comparing only against the project adopted it and the isolation guard then
# refused the launch. The cases below cover both the transient and the pane
# that never leaves the primary at all.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=tests/herdr-test-safety.sh
. "$(dirname "${BASH_SOURCE[0]}")/herdr-test-safety.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-settle)

# make_settle_fakebin <dir> builds a fake tmux whose `#{pane_current_path}`
# query returns FM_FAKE_PANE_STALE for the first FM_FAKE_PANE_STALE_READS
# calls, then FM_FAKE_PANE_PATH forever after - reproducing a pane that
# transiently reports a stale cwd before settling into the real worktree.
make_settle_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*)
    countfile="${FM_FAKE_PANE_COUNTFILE:?FM_FAKE_PANE_COUNTFILE unset}"
    n=0
    [ -f "$countfile" ] && n=$(cat "$countfile")
    n=$((n + 1))
    printf '%s\n' "$n" > "$countfile"
    if [ "$n" -le "${FM_FAKE_PANE_STALE_READS:-0}" ]; then
      printf '%s\n' "${FM_FAKE_PANE_STALE:-}"
    else
      printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    fi
    exit 0
    ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys) printf '%s\n' "$*" >> "${FM_FAKE_TMUX_LOG:-/dev/null}"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# make_settle_case <name> <id> <stale_reads> builds a home, a primary project
# with a real worktree (the eventual settled path), and a separate real git
# repo standing in for the stale path (a real checkout of something else
# entirely, distinct from both the project and the worktree - mirroring the
# live incident where the stale read was another real firstmate home).
make_settle_case() {
  local name=$1 id=$2 stale_reads=$3 case_dir home proj wt stale fakebin countfile
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  stale="$case_dir/stale-other-checkout"
  countfile="$case_dir/pane-call-count"
  fakebin=$(make_settle_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_git_init_commit "$stale"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise settled-worktree detection for $id.

## Firstmate spec
Record only the pane's stable worktree.
EOF
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$stale|$fakebin|$countfile|$stale_reads"
}

read_settle_record() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR STALE_DIR FAKEBIN_DIR COUNTFILE STALE_READS <<EOF
$1
EOF
}

run_settle_spawn() {
  local id=$1
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" FM_FAKE_PANE_STALE="$STALE_DIR" \
    FM_FAKE_PANE_STALE_READS="$STALE_READS" FM_FAKE_PANE_COUNTFILE="$COUNTFILE" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
}

# A single stale first read (the exact incident) must not be accepted: the
# loop should keep polling until two consecutive reads agree, landing on the
# real settled worktree instead.
test_single_stale_first_read_is_not_accepted() {
  local rec id out status
  id=settle-single-stale-z1
  rec=$(make_settle_case settle-single "$id" 1)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed once the pane settles"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the settled worktree"
  assert_no_grep "worktree=$STALE_DIR" "$HOME_DIR/state/$id.meta" \
    "meta wrongly recorded the transient stale path as the worktree"
  pass "a single transient stale pane_current_path read is not accepted as the worktree"
}

# A pane that reports the real worktree from the very first read costs exactly
# one confirming read - not a whole extra polling cycle on top of it. Counting
# the pane reads measures the loop itself; wall-clock time would fold in every
# other cost of a spawn (fetch, trust registration) and drift with the machine.
test_already_settled_pane_costs_one_confirm_read() {
  local rec id out status reads
  id=settle-already-settled-z2
  rec=$(make_settle_case settle-already-settled "$id" 0)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed when the pane is already settled"$'\n'"$out"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the already-settled worktree"
  reads=$(cat "$COUNTFILE")
  [ "$reads" -eq 3 ] || fail "already-settled pane took $reads reads to confirm - expected the first read, one confirmation, and the launch-boundary cwd check"
  pass "an already-settled pane confirms on the next read, not a whole extra cycle"
}

# make_primary_case <name> <id> <stale_reads> builds the linked-home shape: the
# spawning project is itself a LINKED worktree of the repository, and the path
# the pane transiently reports is that repository's PRIMARY checkout. `treehouse
# get` reports the repository it is preparing a slot from as its own cwd while
# it is still fetching and checking out, so the pane reads the primary for the
# first seconds. The primary is not the spawning project, so a poll that only
# compares against the project accepts it as the worktree, and the isolation
# guard then refuses the launch even though treehouse went on to enter a real
# slot. The settled path is a second linked worktree of the same repository.
make_primary_case() {
  local name=$1 id=$2 stale_reads=$3 case_dir home primary proj wt fakebin countfile
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  primary="$case_dir/primary"
  proj="$case_dir/mate"
  wt="$case_dir/slot"
  countfile="$case_dir/pane-call-count"
  fakebin=$(make_settle_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" codex
  fm_git_worktree "$primary" "$proj" "mate-$name"
  git -C "$primary" worktree add --quiet -b "slot-$name" "$wt"
  fm_test_spawn_brief "$home" "$id" "Exercise primary-checkout transient detection for $id."
  printf '%s\n' "$case_dir|$home|$proj|$wt|$primary|$fakebin|$countfile|$stale_reads"
}

# The exact incident: the pane reports the repository primary for the first
# reads, then settles into the slot treehouse actually created. The primary must
# never be adopted as the worktree, so the spawn lands on the settled slot.
test_transient_primary_checkout_is_not_accepted() {
  local rec id out status
  id=settle-primary-transient-z3
  rec=$(make_primary_case settle-primary-transient "$id" 3)
  read_settle_record "$rec"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed once the pane leaves the primary checkout"$'\n'"$out"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the settled worktree"
  assert_no_grep "worktree=$STALE_DIR" "$HOME_DIR/state/$id.meta" \
    "meta wrongly recorded the repository primary checkout as the worktree"
  pass "a transient primary-checkout pane read is not accepted as the worktree"
}

# A pane that never leaves the primary checkout must still fail at the deadline
# rather than waiting forever or recording the primary.
test_primary_checkout_that_never_settles_fails_at_the_deadline() {
  local rec id out status
  id=settle-primary-stuck-z4
  rec=$(make_primary_case settle-primary-stuck "$id" 100000)
  read_settle_record "$rec"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"

  out=$(run_settle_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a pane that never left the primary checkout"$'\n'"$out"
  assert_contains "$out" "did not enter an isolated worktree" \
    "spawn did not explain that the pane never reached an isolated worktree"
  assert_contains "$out" "$STALE_DIR" \
    "the refusal did not name the path the pane kept reporting"
  assert_contains "$out" "repository's primary checkout" \
    "the refusal did not say why that path was rejected"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn published task metadata"
  pass "a pane stuck on the primary checkout fails loudly at the deadline"
}

test_single_stale_first_read_is_not_accepted
test_already_settled_pane_costs_one_confirm_read
test_transient_primary_checkout_is_not_accepted
test_primary_checkout_that_never_settles_fails_at_the_deadline

# --- Herdr: the pane is born in a worktree this process leased --------------
#
# Herdr saves a pane at its creation cwd and resumes the agent there, and the
# nested shell `treehouse get` opens never changes that cwd, so a restored
# worker used to wake in the project clone. A fresh Herdr ship or scout now
# leases its slot from the spawn process and creates the pane inside it.

# make_leasing_treehouse <fakebin> <log> <slot>: `get` prints <slot> and every
# call is logged; FM_FAKE_TREEHOUSE_GET_FAIL=1 makes `get` fail.
make_leasing_treehouse() {
  local fakebin=$1 log=$2 slot=$3
  cat > "$fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\\n' "\$*" >> "$log"
case "\${1:-}" in
  get) [ "\${FM_FAKE_TREEHOUSE_GET_FAIL:-0}" = 1 ] && exit 1; printf '%s\\n' "$slot" ;;
  status) printf '[]\\n' ;;
esac
exit 0
SH
  chmod +x "$fakebin/treehouse"
}

# make_spawn_herdr_fake <fakebin>: a stateful `herdr` that logs every call to
# $FM_FAKE_HERDR_STATE/calls.log and remembers the cwd each tab/workspace was
# created with, which is what its pane reads report. FM_FAKE_HERDR_TAB_FAIL=1
# fails `tab create`; FM_FAKE_HERDR_FG_CWD overrides the reported cwd.
make_spawn_herdr_fake() {
  local fakebin=$1
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
st=${FM_FAKE_HERDR_STATE:?}
printf '%s\n' "$*" >> "$st/calls.log"
argv=("$@")
opt() { local i; for ((i = 0; i < ${#argv[@]} - 1; i++)); do [ "${argv[i]}" = "$1" ] && { printf '%s' "${argv[i + 1]}"; return; }; done; }
next() { local n; n=$(( $(cat "$st/n.$1" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$st/n.$1"; echo "$n"; }
case "$1 ${2:-}" in
  "status --json")
    printf '{"client":{"version":"%s","protocol":%s},"server":{"running":true,"compatible":true}}\n' \
      "${FM_FAKE_HERDR_VERSION:-0.7.1}" "${FM_FAKE_HERDR_PROTOCOL:-14}" ;;
  "workspace list") echo '{"result":{"workspaces":[]}}' ;;
  "workspace create")
    w=w$(next w); t=$w.t$(next t); p=$t.p; opt --cwd > "$st/cwd.$p"
    printf '{"result":{"workspace":{"workspace_id":"%s"},"tab":{"tab_id":"%s"},"root_pane":{"pane_id":"%s"}}}\n' "$w" "$t" "$p" ;;
  "tab list") echo '{"result":{"tabs":[]}}' ;;
  "tab create")
    [ "${FM_FAKE_HERDR_TAB_FAIL:-0}" = 1 ] && exit 1
    w=$(opt --workspace); t=$w.t$(next t); p=$t.p; opt --cwd > "$st/cwd.$p"
    printf '{"result":{"tab":{"tab_id":"%s"},"root_pane":{"pane_id":"%s"}}}\n' "$t" "$p" ;;
  "pane get")
    cwd=${FM_FAKE_HERDR_FG_CWD:-$(cat "$st/cwd.$3" 2>/dev/null)}
    printf '{"result":{"pane":{"pane_id":"%s","cwd":"%s","foreground_cwd":"%s"}}}\n' "$3" "$cwd" "$cwd" ;;
  *) echo '{"result":{}}' ;;
esac
SH
  chmod +x "$fakebin/herdr"
}

# make_herdr_case <name> <id>: a home, a project clone, a Treehouse-shaped pool
# slot (<pool>/1/<repo>, a linked worktree of the clone), and fakes for both CLIs.
make_herdr_case() {
  local name=$1 id=$2 case_dir home proj pool slot fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  pool="$case_dir/pool"
  slot="$pool/1/project"
  fakebin=$(fm_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" codex
  fm_git_init_commit "$proj"
  mkdir -p "$pool/1" "$case_dir/herdr-state"
  : > "$case_dir/herdr-state/calls.log"
  : > "$case_dir/treehouse.log"
  git -C "$proj" worktree add --quiet -b "slot-$name" "$slot"
  printf '{}\n' > "$pool/treehouse-state.json"
  fm_test_spawn_brief "$home" "$id" "Exercise the Herdr lease-first spawn for $id."
  make_leasing_treehouse "$fakebin" "$case_dir/treehouse.log" "$slot"
  make_spawn_herdr_fake "$fakebin"
  fm_test_fake_sleep_noop "$fakebin"
  printf '%s\n' "$case_dir|$home|$proj|$slot|$fakebin"
}

read_herdr_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR SLOT_DIR FAKEBIN_DIR <<RECORD
$1
RECORD
  HERDR_LOG="$CASE_DIR/herdr-state/calls.log"
  TREEHOUSE_LOG="$CASE_DIR/treehouse.log"
}

run_herdr_spawn() {
  local id=$1
  shift
  (
    herdr_forget_inherited_pane
    FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
      FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
      FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
      FM_SPAWN_NO_GUARD=1 HERDR_SESSION=fake-spawn-lab FM_FAKE_HERDR_STATE="$CASE_DIR/herdr-state" \
      PATH="$FAKEBIN_DIR:$PATH" \
      "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off --backend herdr "$@" 2>&1
  )
}

test_herdr_spawn_creates_the_pane_in_the_leased_worktree() {
  local rec id out status
  id=herdr-lease-first-z5
  rec=$(make_herdr_case herdr-lease-first "$id")
  read_herdr_case "$rec"

  out=$(run_herdr_spawn "$id")
  status=$?
  expect_code 0 "$status" "a Herdr spawn should succeed"$'\n'"$out"
  assert_grep "--cwd $SLOT_DIR --label fm-$id" "$HERDR_LOG" \
    "the task tab was not created in the leased worktree"
  assert_no_grep "--cwd $PROJ_DIR --label fm-$id" "$HERDR_LOG" \
    "a task tab was created in the project clone"
  assert_no_grep "treehouse get" "$HERDR_LOG" "treehouse get was typed into the pane"
  assert_grep "get --lease --lease-holder $id" "$TREEHOUSE_LOG" \
    "the slot was not leased to the task from the spawn process"
  assert_no_grep "return" "$TREEHOUSE_LOG" "a published spawn returned its lease"
  ! grep -q "^lease " "$TREEHOUSE_LOG" || fail "the already-leased slot was leased a second time"
  assert_grep "worktree=$SLOT_DIR" "$HOME_DIR/state/$id.meta" "meta did not record the leased worktree"
  assert_grep "task=$id" "$CASE_DIR/pool/1/.fm-slot-owner" "the slot-owner claim was not written"
  pass "a Herdr spawn leases its slot first and creates the tab inside it"
}

test_herdr_spawn_returns_the_lease_when_it_fails_before_the_record() {
  local rec id out status
  # The tab cannot be created: the lease taken just before must go back.
  id=herdr-lease-tabfail-z7
  rec=$(make_herdr_case herdr-lease-tabfail "$id")
  read_herdr_case "$rec"
  out=$(FM_FAKE_HERDR_TAB_FAIL=1 run_herdr_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded though the tab could not be created"$'\n'"$out"
  assert_grep "return --force $SLOT_DIR" "$TREEHOUSE_LOG" "the lease was not returned after the tab failed"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "a failed spawn published a task record"

  # The pane comes up outside the worktree: the launch assertion refuses, after
  # the lease and the pane exist, and the lease must still go back.
  id=herdr-lease-wrongcwd-z8
  rec=$(make_herdr_case herdr-lease-wrongcwd "$id")
  read_herdr_case "$rec"
  out=$(FM_FAKE_HERDR_FG_CWD="$PROJ_DIR" run_herdr_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn launched a worker whose pane was outside its worktree"$'\n'"$out"
  assert_contains "$out" "not its recorded worktree" "the refusal did not name the cwd mismatch"
  assert_grep "return --force $SLOT_DIR" "$TREEHOUSE_LOG" "the lease was not returned after the launch assertion refused"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "a refused spawn published a task record"

  # No lease is taken at all: nothing to return, no pane created.
  id=herdr-lease-getfail-z9
  rec=$(make_herdr_case herdr-lease-getfail "$id")
  read_herdr_case "$rec"
  out=$(FM_FAKE_TREEHOUSE_GET_FAIL=1 run_herdr_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded though treehouse could not lease a slot"$'\n'"$out"
  assert_no_grep "return" "$TREEHOUSE_LOG" "a lease that was never taken was returned"
  assert_no_grep "tab create" "$HERDR_LOG" "a pane was created though no worktree was leased"
  pass "a Herdr spawn returns its early lease when it fails before the task record is published"
}

test_tmux_spawn_still_takes_its_slot_through_the_pane() {
  local rec id out status
  id=settle-tmux-unchanged-z10
  rec=$(make_settle_case settle-tmux-unchanged "$id" 0)
  read_settle_record "$rec"
  : > "$HOME_DIR/treehouse.log"
  make_leasing_treehouse "$FAKEBIN_DIR" "$HOME_DIR/treehouse.log" "$WT_DIR"

  out=$(FM_FAKE_TMUX_LOG="$HOME_DIR/tmux.log" run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "a tmux spawn should still succeed"$'\n'"$out"
  assert_grep "treehouse get" "$HOME_DIR/tmux.log" "tmux no longer types treehouse get into its pane"
  assert_no_grep "get --lease" "$HOME_DIR/treehouse.log" "a tmux spawn leased its slot from the spawn process"
  pass "tmux spawns keep their pane-driven treehouse get"
}

test_herdr_spawn_creates_the_pane_in_the_leased_worktree
test_herdr_spawn_returns_the_lease_when_it_fails_before_the_record
test_tmux_spawn_still_takes_its_slot_through_the_pane

echo "# all fm-spawn-worktree-settle tests passed"
