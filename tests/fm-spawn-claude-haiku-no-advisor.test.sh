#!/usr/bin/env bash
# tests/fm-spawn-claude-haiku-no-advisor.test.sh - a Claude worker on a
# Haiku-tier model starts with CLAUDE_CODE_DISABLE_ADVISOR_TOOL=1; every other
# model, and no model, leaves it unset.
#
# Drives the real spawn against a fake pane, then executes the launch command
# the pane received with `claude` replaced by a probe that prints the variable.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-haiku-advisor)

# launch_env <case-name> [model...] : echoes the probe's view of the variable.
launch_env() {
  local name=$1 case_dir home proj wt fakebin launchlog panelog out status id="adv-$1"
  shift
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"; proj="$case_dir/project"; wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"; panelog="$case_dir/pane.log"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" claude
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$id"
  : > "$launchlog"; : > "$panelog"
  out=$(FM_FAKE_LAUNCH_LOG="$launchlog" FM_FAKE_PANE_LOG="$panelog" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --mode no-mistakes --yolo off "$@")
  status=$?
  [ "$status" -eq 0 ] || fail "$name: spawn failed ($status): $out"
  printf '#!/bin/sh\nprintf "%%s\\n" "${CLAUDE_CODE_DISABLE_ADVISOR_TOOL-unset}"\n' > "$fakebin/claude"
  chmod +x "$fakebin/claude"
  env -i HOME="$case_dir/pane-home" PATH="$fakebin:$PATH" TERM=xterm TMUX=synthetic-pane \
    /bin/sh -c "$(grep '^export ' "$panelog")
$(cat "$launchlog")"
}

for m in haiku claude-haiku-5-5 Haiku; do
  assert_equals 1 "$(launch_env "on-$m" --model "$m")" "--model $m should disable the advisor"
done
for m in opus sonnet claude-opus-5-5; do
  assert_equals unset "$(launch_env "off-$m" --model "$m")" "--model $m must keep the advisor"
done
assert_equals unset "$(launch_env no-model)" "no model must keep the advisor"
pass "advisor disabled only for Haiku-tier models"
