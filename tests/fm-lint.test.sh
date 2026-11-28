#!/usr/bin/env bash
# Parity guard for firstmate's shell-lint definition.
#
# bin/fm-lint.sh is the single owner invoked by CI
# (.github/workflows/ci.yml) and by the pre-push gate (.no-mistakes.yaml
# commands.lint). CI and the local gate deliberately select different roots;
# bin/fm-lint.sh owns their analysis modes, memory fallback, configuration,
# and tool versions.
# Regression origin: with no commands.lint configured, the local no-mistakes
# lint step never ran the deterministic shell lint, so PRs passed local
# validation yet failed CI on info/warning findings such as SC2015, SC1007, and
# SC2034. A second axis was tool-version skew: CI's ShellCheck floated with the
# runner image and still emitted SC2015, which ShellCheck retired in 0.11.0.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LINT="$ROOT/bin/fm-lint.sh"
# The resident memory cap needs a systemd user manager, which the lint tests
# neither need nor can rely on (and a CI runner may lack), so every test runs
# without it; the cap tests below switch it on with a stub or a real scope.
export FM_LINT_ROOT_CGROUP_MIB=off
INSTALLER="$ROOT/bin/fm-install-shellcheck.sh"
# The pinned version, read from the single source (the one owner itself).
REQUIRED=$("$LINT" --required-version)

# Official GitHub release asset sha256 values for shellcheck v0.11.0 .tar.xz
# archives (https://github.com/koalaman/shellcheck/releases/tag/v0.11.0). Tests
# compare installer behavior against these published digests, not script source.
SHELLCHECK_SHA_LINUX_X86_64=8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198
SHELLCHECK_SHA_LINUX_AARCH64=12b331c1d2db6b9eb13cfca64306b1b157a86eb69db83023e261eaa7e7c14588
SHELLCHECK_SHA_DARWIN_X86_64=3c89db4edcab7cf1c27bff178882e0f6f27f7afdf54e859fa041fca10febe4c6
SHELLCHECK_SHA_DARWIN_AARCH64=56affdd8de5527894dca6dc3d7e0a99a873b0f004d7aabc30ae407d3f48b0a79

# fm_install_stub_uname <fakebin>: uname -s / uname -m from FM_TEST_UNAME_S/M.
fm_install_stub_uname() {
  local fakebin=$1
  cat > "$fakebin/uname" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  -s) printf '%s\n' "${FM_TEST_UNAME_S:-Linux}" ;;
  -m) printf '%s\n' "${FM_TEST_UNAME_M:-x86_64}" ;;
  *) printf '%s\n' "${FM_TEST_UNAME_S:-Linux}" ;;
esac
SH
  chmod +x "$fakebin/uname"
}

# fm_install_stub_curl <fakebin>: log the URL, fail CURL_FAIL_UNTIL times, then
# write an empty file at -o. CURL_COUNT and CURL_URL_LOG are paths the stub
# updates when invoked.
fm_install_stub_curl() {
  local fakebin=$1
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
count=0
[ ! -f "${CURL_COUNT:-}" ] || count=$(cat "$CURL_COUNT")
count=$((count + 1))
[ -z "${CURL_COUNT:-}" ] || printf '%s\n' "$count" > "$CURL_COUNT"
url=
out=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o)
      out=$2
      shift 2
      ;;
    -*)
      shift
      ;;
    *)
      url=$1
      shift
      ;;
  esac
done
[ -z "${CURL_URL_LOG:-}" ] || printf '%s\n' "$url" >> "$CURL_URL_LOG"
fail_until=${CURL_FAIL_UNTIL:-0}
[ "$count" -gt "$fail_until" ] || exit 22
: > "$out"
exit 0
SH
  chmod +x "$fakebin/curl"
}

# fm_install_stub_hasher <fakebin> <name>: sha256sum or shasum stub that prints
# SHA256_STUB_HASH and records the invocation on HASHER_LOG. shasum requires -a 256.
fm_install_stub_hasher() {
  local fakebin=$1 name=$2
  cat > "$fakebin/$name" <<'SH'
#!/usr/bin/env bash
self=${0##*/}
if [ -n "${HASHER_LOG:-}" ]; then
  printf '%s\n' "$self $*" >> "$HASHER_LOG"
fi
file=$1
if [ "$self" = shasum ]; then
  algo=
  file=
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -a)
        algo=$2
        shift 2
        ;;
      *)
        file=$1
        shift
        ;;
    esac
  done
  [ "$algo" = 256 ] || exit 1
fi
printf '%s  %s\n' "${SHA256_STUB_HASH:?}" "$file"
SH
  chmod +x "$fakebin/$name"
}

fm_install_stub_tar_shellcheck() {
  local fakebin=$1
  cat > "$fakebin/tar" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  if [ "$1" = "-C" ]; then
    mkdir -p "$2/shellcheck-v0.11.0"
    cat > "$2/shellcheck-v0.11.0/shellcheck" <<'EOF'
#!/usr/bin/env bash
printf 'ShellCheck - shell script analysis tool\nversion: 0.11.0\n'
EOF
    chmod +x "$2/shellcheck-v0.11.0/shellcheck"
    exit 0
  fi
  shift
done
exit 2
SH
  chmod +x "$fakebin/tar"
}

fm_install_stub_sleep() {
  local fakebin=$1
  cat > "$fakebin/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/sleep"
}

# True only when the resolved shellcheck is exactly the pinned version, so the
# lint-running tests below match what CI enforces instead of a runner default.
pinned_ready() {
  command -v shellcheck >/dev/null 2>&1 || return 1
  [ "$(shellcheck --version | awk '/^version:/ {print $2; exit}')" = "$REQUIRED" ]
}

test_help_reports_the_complete_interface() {
  local help
  help=$("$LINT" --help) || fail "fm-lint.sh --help failed"
  assert_contains "$help" "--telemetry" "fm-lint.sh --help omitted --telemetry"
  assert_contains "$help" "--required-version" "fm-lint.sh --help omitted --required-version"
  assert_contains "$help" "--list-files" "fm-lint.sh --help omitted --list-files"
  assert_contains "$help" "--help" "fm-lint.sh --help omitted --help"
  assert_contains "$help" "--fast" "fm-lint.sh --help omitted --fast"
  assert_contains "$help" "--changed" "fm-lint.sh --help omitted --changed"
  assert_contains "$help" "SC1091" "fm-lint.sh --help omitted the local SC1091 exclusion"
  assert_contains "$help" "SC2034" "fm-lint.sh --help omitted the local SC2034 exclusion"
  assert_contains "$help" "SC2153" "fm-lint.sh --help omitted the local SC2153 exclusion"
  assert_contains "$help" "SC2329" "fm-lint.sh --help omitted the local SC2329 exclusion"
  pass "fm-lint.sh --help reports the complete executable interface"
}

test_list_files_reports_the_shell_inventory() {
  local listed expected
  # CI=true forces the full canonical set regardless of the ambient branch or
  # working-tree diff a local test run happens to have, so this stays a pure
  # inventory check independent of fm-lint.sh's own changed-file mode below.
  # Hidden scripts are outside the documented shell-glob inventory.
  listed=$(CI=true "$LINT" --list-files)
  expected=$(find bin bin/backends tests -maxdepth 1 -type f -name '*.sh' ! -name '.*' -print | LC_ALL=C sort)
  [ "$(printf '%s\n' "$listed" | LC_ALL=C sort)" = "$expected" ] \
    || fail "fm-lint.sh --list-files did not return the complete shell inventory"
  pass "fm-lint.sh --list-files reports the complete shell inventory"
}

test_canonical_partitions_preserve_full_lint() {
  local tmp fakebin all part selected log flags mode rc option invocation_count root_count
  tmp=$(fm_test_tmproot fm-lint-partitions)
  fakebin="$tmp/bin"
  mkdir -p "$fakebin"
  all=$(CI=true "$LINT" --list-files | LC_ALL=C sort)
  : > "$tmp/union"
  for part in 1of7 2of7 3of7 4of7 5of7 6of7 7of7; do
    selected=$(CI=false GITHUB_ACTIONS=false "$LINT" --partition "$part" --list-files) \
      || fail "partition $part must select full canonical roots even on a local branch"
    [ -n "$selected" ] || fail "empty lint partition $part"
    printf '%s\n' "$selected" >> "$tmp/union"
    [ "$selected" = "$("$LINT" --partition "$part" --list-files)" ] \
      || fail "partition $part is nondeterministic"
    log="$tmp/$part.roots"
    flags="$tmp/$part.flags"
    mode="$tmp/$part.mode"
    fm_lint_stub_shellcheck "$fakebin" "$log"
    PATH="$fakebin:$PATH" FM_TEST_FLAG_LOG="$flags" FM_TEST_MODE_LOG="$mode" \
      "$LINT" --partition "$part" > "$tmp/$part.out" 2>&1 \
      || fail "canonical partition $part failed: $(cat "$tmp/$part.out")"
    [ "$(LC_ALL=C sort "$log")" = "$(printf '%s\n' "$selected" | LC_ALL=C sort)" ] \
      || fail "partition $part executed a different root set than it listed"
    [ "$(LC_ALL=C sort -u "$flags")" = "$(printf 'exclude=none\nexternal-sources=yes')" ] \
      || fail "partition $part weakened source-aware analysis"
    [ "$(LC_ALL=C sort -u "$mode")" = on ] || fail "partition $part disabled full analysis"
    root_count=$(printf '%s\n' "$selected" | grep -c .)
    invocation_count=$(grep -c '^external-sources=' "$flags" || true)
    [ "$invocation_count" -eq "$root_count" ] \
      || fail "partition $part used $invocation_count ShellCheck calls for $root_count roots"
    [ "$(grep -c '^fm-lint: begin ' "$tmp/$part.out" || true)" -eq "$root_count" ] \
      || fail "partition $part did not stream a begin record per root"
    [ "$(grep -c '^fm-lint: end ' "$tmp/$part.out" || true)" -eq "$root_count" ] \
      || fail "partition $part did not stream an end record per root"
  done
  [ "$(LC_ALL=C sort "$tmp/union")" = "$all" ] || fail "lint partitions lose or duplicate canonical roots"
  : > "$tmp/union4"
  for part in 1of4 2of4 3of4 4of4; do
    selected=$(CI=false GITHUB_ACTIONS=false "$LINT" --partition "$part" --list-files) \
      || fail "partition $part must list canonical roots"
    printf '%s\n' "$selected" >> "$tmp/union4"
  done
  [ "$(LC_ALL=C sort "$tmp/union4")" = "$all" ] || fail "four lint partitions lose or duplicate canonical roots"
  CI=false GITHUB_ACTIONS=false "$LINT" --partition 1of3 --list-files >/dev/null \
    || fail "generic <k>of<n> must accept 1of3"
  for option in 0of4 5of4 1of0 of4 1of 2of2x; do
    rc=0
    "$LINT" --partition "$option" --list-files > "$tmp/refused" 2>&1 || rc=$?
    [ "$rc" = 2 ] || fail "invalid partition $option was not refused"
  done
  rc=0
  "$LINT" --partition 1of2 --fast > "$tmp/refused" 2>&1 || rc=$?
  [ "$rc" = 2 ] || fail "partition accepted --fast"
  rc=0
  "$LINT" --partition 1of2 bin/fm-lint.sh > "$tmp/refused" 2>&1 || rc=$?
  [ "$rc" = 2 ] || fail "partition accepted an explicit subset"
  pass "seven canonical lint partitions and the generic <k>of<n> form preserve complete source-aware coverage and reject weakened modes"
}

# fm_lint_stub_git <fakebin-dir>: install a git stub for the changed-file mode
# tests below. Its answers are driven by env vars the caller sets before
# invoking fm-lint.sh, so those tests can steer git state without depending on
# this worktree's actual branch, remotes, or history:
#   FM_TEST_GIT_INSIDE_WORKTREE  1 (default) or 0
#   FM_TEST_GIT_BRANCH           branch name for `rev-parse --abbrev-ref HEAD`
#   FM_TEST_GIT_HAS_ORIGIN_MAIN  1 (default) or 0
#   FM_TEST_GIT_HAS_MAIN         1 (default) or 0
#   FM_TEST_GIT_MERGE_BASE_OK    1 (default) or 0
#   FM_TEST_GIT_MERGE_BASE       merge-base value to print when OK
#   FM_TEST_GIT_DIFF_FILE        path to a file of NUL-separated changed paths
#   FM_TEST_GIT_NAME_STATUS_FILE path to a git diff --name-status listing
#                                (tab-separated status and paths). When unset,
#                                the name-status stub synthesizes M lines from
#                                FM_TEST_GIT_DIFF_FILE so existing tests keep
#                                driving both collectors from one fixture.
fm_lint_stub_git() {
  local fakebin=$1
  cat > "$fakebin/git" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "rev-parse --is-inside-work-tree")
    [ "${FM_TEST_GIT_INSIDE_WORKTREE:-1}" = 1 ] || exit 1
    printf 'true\n'
    exit 0
    ;;
  "rev-parse --abbrev-ref HEAD")
    printf '%s\n' "${FM_TEST_GIT_BRANCH:-feature}"
    exit 0
    ;;
  "rev-parse --verify -q origin/main")
    [ "${FM_TEST_GIT_HAS_ORIGIN_MAIN:-1}" = 1 ] && exit 0 || exit 1
    ;;
  "rev-parse --verify -q main")
    [ "${FM_TEST_GIT_HAS_MAIN:-1}" = 1 ] && exit 0 || exit 1
    ;;
  "merge-base "*)
    if [ "${FM_TEST_GIT_MERGE_BASE_OK:-1}" = 1 ]; then
      printf '%s\n' "${FM_TEST_GIT_MERGE_BASE:-fakebase123}"
      exit 0
    fi
    exit 1
    ;;
  "diff --name-only --diff-filter=ACMR -z "*)
    if [ -n "${FM_TEST_GIT_DIFF_FILE:-}" ] && [ -f "$FM_TEST_GIT_DIFF_FILE" ]; then
      cat "$FM_TEST_GIT_DIFF_FILE"
    fi
    exit 0
    ;;
  "diff --name-only --diff-filter=ACMR "*)
    if [ -n "${FM_TEST_GIT_DIFF_FILE:-}" ] && [ -f "$FM_TEST_GIT_DIFF_FILE" ]; then
      after=0
      specs=
      for arg in $*; do
        if [ "$after" = 1 ]; then
          specs="$specs $arg"
        elif [ "$arg" = -- ]; then
          after=1
        fi
      done
      tr '\0' '\n' < "$FM_TEST_GIT_DIFF_FILE" | while IFS= read -r path; do
        [ -n "$path" ] || continue
        if [ -z "${specs# }" ]; then
          printf '%s\n' "$path"
          continue
        fi
        for spec in $specs; do
          if [ "$path" = "$spec" ]; then
            printf '%s\n' "$path"
            break
          fi
        done
      done
    fi
    exit 0
    ;;
  "diff --name-status --diff-filter=ACDMR "*)
    if [ -n "${FM_TEST_GIT_NAME_STATUS_FILE:-}" ] && [ -f "$FM_TEST_GIT_NAME_STATUS_FILE" ]; then
      cat "$FM_TEST_GIT_NAME_STATUS_FILE"
    elif [ -n "${FM_TEST_GIT_DIFF_FILE:-}" ] && [ -f "$FM_TEST_GIT_DIFF_FILE" ]; then
      tr '\0' '\n' < "$FM_TEST_GIT_DIFF_FILE" | while IFS= read -r path; do
        [ -n "$path" ] || continue
        printf 'M\t%s\n' "$path"
      done
    fi
    exit 0
    ;;
  *)
    exit 1
    ;;
esac
SH
  chmod +x "$fakebin/git"
}

# fm_lint_write_diff_file <file> <path>...: writes NUL-separated changed paths
# in the shape `git diff --name-only -z` produces, for FM_TEST_GIT_DIFF_FILE.
fm_lint_write_diff_file() {
  local file=$1
  shift
  printf '%s\0' "$@" > "$file"
}

# fm_lint_write_name_status <file> <line>...: writes `git diff --name-status`
# lines for FM_TEST_GIT_NAME_STATUS_FILE (status, then tab-separated paths).
fm_lint_write_name_status() {
  local file=$1
  shift
  printf '%s\n' "$@" > "$file"
}

# fm_lint_stub_shellcheck <fakebin-dir> <log-file>: install a ShellCheck stub
# that answers --version with the pinned version and otherwise logs the file
# roots it was asked to check (one per line) instead of actually analyzing
# them, so changed-file mode tests can assert exactly which files fm-lint.sh
# selected without depending on real ShellCheck findings. When
# FM_TEST_MODE_LOG is set, it records the effective analysis mode, treating
# ShellCheck's default as full analysis. When FM_TEST_FLAG_LOG is set, it
# records whether --external-sources was passed and the --exclude value.
fm_lint_stub_shellcheck() {
  local fakebin=$1 log=$2
  : > "$log"
  cat > "$fakebin/shellcheck" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --version ]; then
  printf 'ShellCheck - shell script analysis tool\nversion: 0.11.0\n'
  exit 0
fi
# The ratchet check (--include) is a separate invocation that must not disturb
# the per-root accounting below: a listed root (gcc format) still has a
# finding, and an enforced root (default format) is clean.
ratchet=no
gcc=no
for arg in "\$@"; do
  case "\$arg" in --include=*) ratchet=yes ;; gcc) gcc=yes ;; esac
done
if [ "\$ratchet" = yes ]; then
  if [ "\$gcc" = yes ]; then
    for arg in "\$@"; do
      case "\$arg" in -*|gcc) ;; *) printf '%s:1:1: note: stub [SC2248]\n' "\$arg" ;; esac
    done
    exit 1
  fi
  exit 0
fi
mode=on
follow=no
exclude=none
while [ "\$#" -gt 0 ] && [ "\$1" != -- ]; do
  case "\$1" in
    --extended-analysis=false) mode=off ;;
    --external-sources) follow=yes ;;
    --exclude=*) exclude=\${1#--exclude=} ;;
    --exclude)
      shift
      exclude=\${1:-none}
      ;;
  esac
  shift
done
if [ -n "\${FM_TEST_MODE_LOG:-}" ]; then
  printf '%s\n' "\$mode" >> "\$FM_TEST_MODE_LOG"
fi
if [ -n "\${FM_TEST_FLAG_LOG:-}" ]; then
  printf 'external-sources=%s\nexclude=%s\n' "\$follow" "\$exclude" >> "\$FM_TEST_FLAG_LOG"
fi
[ "\$#" -eq 0 ] || shift
printf '%s\n' "\$@" >> "$log"
exit 0
SH
  chmod +x "$fakebin/shellcheck"
}

# fm_lint_bounds_supported: the platform pair the bounded per-root envelope
# needs - a watchdog mechanism and an enforceable address-space limit. macOS
# rejects ulimit -v, so bounded-mode tests run there only when this is true.
fm_lint_bounds_supported() {
  [ -r "$ROOT/bin/fm-timeout-lib.sh" ] || return 1
  ( ulimit -v 65536 ) 2>/dev/null || return 1
  command -v perl >/dev/null 2>&1 \
    || command -v timeout >/dev/null 2>&1 \
    || command -v gtimeout >/dev/null 2>&1 || return 1
  return 0
}

# fm_lint_stub_reactive_shellcheck <fakebin-dir>: a ShellCheck stub whose
# behavior is steered by the basename of the root it is asked to analyze, so
# bounded-execution tests can mix a hang, a memory-limit death, and clean
# roots in one run. A *blocker* root spawns a tracked child (pid written to
# FM_TEST_CHILD_PID), records its own pid on FM_TEST_STUB_PID, and then blocks;
# a *hoarder* root runs a perl allocator that grows to 512 MiB and fails only
# when perl itself reports that the allocation was refused, forwarding perl's
# own error and exiting with GHC's heap-exhaustion status 251, as ShellCheck
# does when its runtime is refused memory; an allocation that succeeds falls
# through like any other root.
# Anything else records its path on FM_TEST_STUB_LOG and exits cleanly.
fm_lint_stub_reactive_shellcheck() {
  local fakebin=$1
  cat > "$fakebin/shellcheck" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
  printf 'ShellCheck - shell script analysis tool\nversion: 0.11.0\n'
  exit 0
fi
case " $* " in *" --include="*) exit 0 ;; esac
target=${!#}
case "$target" in
  *blocker*)
    sleep "${FM_TEST_BLOCK_SECS:-300}" &
    printf '%s\n' "$!" > "${FM_TEST_CHILD_PID:-/dev/null}"
    printf '%s\n' "$$" > "${FM_TEST_STUB_PID:-/dev/null}"
    exec sleep "${FM_TEST_BLOCK_SECS:-300}"
    ;;
  *hoarder*)
    alloc_rc=0
    alloc_err=$(perl -e 'my $s = ""; for (1..512) { $s .= "x" x 1048576 }' 2>&1 >/dev/null) \
      || alloc_rc=$?
    if [ "$alloc_rc" -ne 0 ]; then
      printf '%s\n' "$alloc_err" >&2
      case "$alloc_err" in
        *"Out of memory"*) exit 251 ;;
      esac
      exit "$alloc_rc"
    fi
    ;;
  *oom-exit1*)
    printf 'shellcheck: malloc: resource exhausted (out of memory)\n' >&2
    exit 1
    ;;
  *oom-heap*)
    printf 'shellcheck: Heap exhausted;\n' >&2
    exit 251
    ;;
  *oom-kill*)
    printf 'shellcheck: out of memory (requested 1048576 bytes)\n' >&2
    kill -KILL "$$"
    ;;
  *cap-kill-sources*)
    # Killed without a word, as the kernel does, but only while following sources.
    case " $* " in *" --external-sources "*) kill -KILL "$$" ;; esac
    ;;
  *cap-kill*)
    kill -KILL "$$"
    ;;
  *oom-text-findings*)
    printf '\nIn %s line 2:\nshellcheck: out of memory $x\n                          ^-- SC2086 (info): Double quote to prevent globbing and word splitting.\n' "$target"
    exit 1
    ;;
esac
printf '%s\n' "$target" >> "${FM_TEST_STUB_LOG:-/dev/null}"
exit 0
SH
  chmod +x "$fakebin/shellcheck"
}

test_fast_mode_disables_extended_analysis() {
  local tmp fakebin log mode_log telemetry fixture out
  tmp=$(fm_test_tmproot fm-lint-fast-mode)
  fakebin=$(fm_fakebin "$tmp")
  fixture="$tmp/fixture.sh"
  log="$tmp/shellcheck.log"
  mode_log="$tmp/mode.log"
  telemetry="$tmp/telemetry.tsv"
  cat > "$fixture" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${1:-ok}"
SH
  chmod +x "$fixture"
  fm_lint_stub_shellcheck "$fakebin" "$log"

  out=$(PATH="$fakebin:$PATH" GITHUB_ACTIONS='' CI='' FM_LINT_JOBS=1 \
    FM_TEST_MODE_LOG="$mode_log" "$LINT" --fast --telemetry "$telemetry" "$fixture" 2>&1) \
    || fail "fast lint mode failed"$'\n'"$out"
  [ "$(cat "$mode_log")" = off ] \
    || fail "fast lint mode did not disable extended analysis"
  [ "$(cat "$log")" = "$fixture" ] \
    || fail "fast lint mode did not lint the requested root"
  assert_grep $'analysis_mode\tfast' "$telemetry" "telemetry did not record fast analysis mode"
  pass "fm-lint.sh --fast disables ShellCheck extended analysis"
}

test_ci_defaults_to_full_analysis() {
  local tmp fakebin log mode_log fixture out
  tmp=$(fm_test_tmproot fm-lint-ci-analysis)
  fakebin=$(fm_fakebin "$tmp")
  fixture="$tmp/fixture.sh"
  log="$tmp/shellcheck.log"
  mode_log="$tmp/mode.log"
  cat > "$fixture" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${1:-ok}"
SH
  chmod +x "$fixture"
  fm_lint_stub_shellcheck "$fakebin" "$log"

  out=$(PATH="$fakebin:$PATH" CI=true GITHUB_ACTIONS=true FM_LINT_FAST=1 FM_LINT_JOBS=1 \
    FM_TEST_MODE_LOG="$mode_log" "$LINT" "$fixture" 2>&1) \
    || fail "CI full lint mode failed"$'\n'"$out"
  [ "$(cat "$mode_log")" = on ] \
    || fail "CI default did not keep full ShellCheck analysis"
  pass "fm-lint.sh keeps full ShellCheck analysis by default in CI"
}

test_ci_rejects_explicit_fast_mode() {
  local tmp fakebin log fixture out rc
  tmp=$(fm_test_tmproot fm-lint-ci-reject-fast)
  fakebin=$(fm_fakebin "$tmp")
  fixture="$tmp/fixture.sh"
  log="$tmp/shellcheck.log"
  cat > "$fixture" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${1:-ok}"
SH
  chmod +x "$fixture"
  fm_lint_stub_shellcheck "$fakebin" "$log"

  rc=0
  out=$(PATH="$fakebin:$PATH" CI=true GITHUB_ACTIONS=true FM_LINT_JOBS=1 \
    "$LINT" --fast "$fixture" 2>&1) || rc=$?
  [ "$rc" -eq 2 ] \
    || fail "CI accepted explicit fast lint mode (exit $rc)"$'\n'"$out"
  assert_contains "$out" "--fast is local-only" \
    "CI fast-mode rejection did not explain the policy"
  [ ! -s "$log" ] || fail "CI invoked ShellCheck after rejecting fast mode"
  pass "fm-lint.sh rejects explicit --fast mode in CI"
}

test_fast_mode_catches_a_real_lint_defect() {
  if ! pinned_ready; then
    pass "SKIP (ShellCheck $REQUIRED not resolved): fast lint-defect regression check"
    return
  fi
  local tmp bad out rc
  tmp=$(fm_test_tmproot fm-lint-fast-bad)
  bad="$tmp/bad.sh"
  cat > "$bad" <<'SH'
#!/usr/bin/env bash
foo() {
  local a= b=
  echo "$a$b"
}
foo
SH
  rc=0
  out=$(GITHUB_ACTIONS='' CI='' "$LINT" --fast "$bad" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "fast lint mode passed a known-bad fixture"$'\n'"$out"
  assert_contains "$out" "SC1007" "fast lint mode did not report the expected ShellCheck finding"
  pass "fm-lint.sh --fast catches an ordinary shell lint defect"
}

test_changed_mode_lints_only_the_changed_file() {
  local tmp fakebin log diff_file out target
  tmp=$(fm_test_tmproot fm-lint-changed)
  fakebin=$(fm_fakebin "$tmp")
  fm_lint_stub_git "$fakebin"
  log="$tmp/shellcheck.log"
  fm_lint_stub_shellcheck "$fakebin" "$log"
  diff_file="$tmp/diff.nul"
  target="bin/fm-afk-launch.sh"
  fm_lint_write_diff_file "$diff_file" "$target" "README.md"

  # Clear the ambient CI/GITHUB_ACTIONS signals so changed-file mode is actually
  # exercised: a CI run sets them and would otherwise force the full lint here.
  out=$(PATH="$fakebin:$PATH" GITHUB_ACTIONS='' CI='' FM_LINT_JOBS=1 \
    FM_TEST_GIT_BRANCH=feature \
    FM_TEST_GIT_DIFF_FILE="$diff_file" "$LINT" 2>&1) \
    || fail "changed-mode lint run failed"$'\n'"$out"
  [ "$(cat "$log")" = "$target" ] \
    || fail "changed-mode lint did not run ShellCheck on exactly the changed file"$'\n'"logged: $(cat "$log")"
  pass "fm-lint.sh changed mode lints only the changed canonical file"
}

test_ci_forces_full_lint_even_with_empty_diff() {
  local listed expected
  # No git stub: CI=true must short-circuit fm-lint.sh's mode selection before
  # it ever consults git, so this proves CI wins regardless of local diff state.
  listed=$(CI=true "$LINT" --list-files)
  expected=$(find bin bin/backends tests -maxdepth 1 -type f -name '*.sh' ! -name '.*' -print | LC_ALL=C sort)
  [ "$(printf '%s\n' "$listed" | LC_ALL=C sort)" = "$expected" ] \
    || fail "CI=true did not force the full canonical file set"
  pass "fm-lint.sh forces a full lint in CI even when the local diff would be empty"
}

test_main_branch_forces_full_lint() {
  local tmp fakebin listed expected
  tmp=$(fm_test_tmproot fm-lint-main-full)
  fakebin=$(fm_fakebin "$tmp")
  fm_lint_stub_git "$fakebin"

  # Clear CI/GITHUB_ACTIONS so the on-main branch is what forces the full lint,
  # not the ambient CI signal a real CI run would otherwise supply.
  listed=$(PATH="$fakebin:$PATH" GITHUB_ACTIONS='' CI='' \
    FM_TEST_GIT_BRANCH=main "$LINT" --list-files)
  expected=$(find bin bin/backends tests -maxdepth 1 -type f -name '*.sh' ! -name '.*' -print | LC_ALL=C sort)
  [ "$(printf '%s\n' "$listed" | LC_ALL=C sort)" = "$expected" ] \
    || fail "fm-lint.sh did not force a full lint when HEAD is on main"
  pass "fm-lint.sh forces a full lint when HEAD is on main"
}

test_explicit_path_bypasses_changed_logic() {
  local tmp fakebin log out target
  tmp=$(fm_test_tmproot fm-lint-explicit-override)
  fakebin=$(fm_fakebin "$tmp")
  fm_lint_stub_git "$fakebin"
  log="$tmp/shellcheck.log"
  fm_lint_stub_shellcheck "$fakebin" "$log"
  target="bin/fm-install-shellcheck.sh"

  # The git stub reports a broken merge-base, which would force a full lint
  # under the no-args default. Clearing CI/GITHUB_ACTIONS keeps changed-file
  # selection live so this proves the explicit path bypasses it, not that CI
  # already forced full mode. An explicit path must never even consult git.
  out=$(PATH="$fakebin:$PATH" GITHUB_ACTIONS='' CI='' FM_LINT_JOBS=1 \
    FM_TEST_GIT_MERGE_BASE_OK=0 \
    "$LINT" "$target" 2>&1) || fail "explicit-path lint failed"$'\n'"$out"
  [ "$(cat "$log")" = "$target" ] \
    || fail "explicit path lint did not run on exactly the requested file"$'\n'"logged: $(cat "$log")"
  pass "fm-lint.sh explicit paths bypass changed-file mode selection"
}

test_zero_changed_files_exits_clean() {
  local tmp fakebin diff_file out rc
  tmp=$(fm_test_tmproot fm-lint-zero-changed)
  fakebin=$(fm_fakebin "$tmp")
  fm_lint_stub_git "$fakebin"
  diff_file="$tmp/diff.nul"
  : > "$diff_file"

  rc=0
  # Clear CI/GITHUB_ACTIONS so changed-file mode runs and can reach the empty
  # target set; a CI run would otherwise force a full lint instead.
  out=$(PATH="$fakebin:$PATH" GITHUB_ACTIONS='' CI='' FM_TEST_GIT_BRANCH=feature \
    FM_TEST_GIT_DIFF_FILE="$diff_file" "$LINT" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "zero changed lint targets must exit 0, got $rc"$'\n'"$out"
  assert_contains "$out" "ShellCheck 0.11.0" "zero-changed run did not print the ShellCheck version line"
  assert_contains "$out" "no changed lint targets" "zero-changed run did not note the empty target set"
  assert_contains "$out" "workflow files valid" \
    "zero-changed run skipped workflow YAML validation"
  pass "fm-lint.sh exits 0 with a note when the local branch has no changed lint targets"
}

test_list_files_respects_changed_mode() {
  local tmp fakebin diff_file listed
  tmp=$(fm_test_tmproot fm-lint-list-changed)
  fakebin=$(fm_fakebin "$tmp")
  fm_lint_stub_git "$fakebin"
  diff_file="$tmp/diff.nul"
  # A real canonical file, a non-canonical file, and a canonical-looking path
  # that does not exist: only the first should survive into the listed set.
  fm_lint_write_diff_file "$diff_file" \
    "tests/fm-lint.test.sh" "docs/README.md" "bin/definitely-not-real-file.sh"

  # Clear CI/GITHUB_ACTIONS so --list-files reflects the changed set rather than
  # the full canonical set a CI run's ambient signals would otherwise force.
  listed=$(PATH="$fakebin:$PATH" GITHUB_ACTIONS='' CI='' FM_TEST_GIT_BRANCH=feature \
    FM_TEST_GIT_DIFF_FILE="$diff_file" "$LINT" --list-files)
  [ "$listed" = "tests/fm-lint.test.sh" ] \
    || fail "--list-files did not report the would-be changed set in changed mode"$'\n'"got: $listed"
  pass "fm-lint.sh --list-files reports the would-be changed set in changed mode"
}

fm_lint_assert_flag_log() {
  local flag_log=$1 expected_follow=$2 expected_exclude=$3
  [ -s "$flag_log" ] || fail "ShellCheck was not invoked; flag log is empty"
  awk -v follow="$expected_follow" -v exclude="$expected_exclude" '
    BEGIN { bad=0; saw=0 }
    /^external-sources=/ { saw=1; if ($0 != "external-sources=" follow) bad=1 }
    /^exclude=/ { if ($0 != "exclude=" exclude) bad=1 }
    END { exit (saw && !bad) ? 0 : 1 }
  ' "$flag_log" \
    || fail "ShellCheck flags were not external-sources=$expected_follow exclude=$expected_exclude"$'\n'"$(cat "$flag_log")"
}

test_changed_mode_drops_external_sources_and_excludes_cross_file_codes() {
  local tmp fakebin log flag_log mode_log diff_file telemetry out target
  tmp=$(fm_test_tmproot fm-lint-local-nox)
  fakebin=$(fm_fakebin "$tmp")
  fm_lint_stub_git "$fakebin"
  log="$tmp/shellcheck.log"
  flag_log="$tmp/flags.log"
  mode_log="$tmp/mode.log"
  telemetry="$tmp/telemetry.tsv"
  fm_lint_stub_shellcheck "$fakebin" "$log"
  diff_file="$tmp/diff.nul"
  target="bin/fm-afk-launch.sh"
  fm_lint_write_diff_file "$diff_file" "$target"

  out=$(PATH="$fakebin:$PATH" GITHUB_ACTIONS='' CI='' FM_LINT_JOBS=1 \
    FM_TEST_GIT_BRANCH=feature \
    FM_TEST_GIT_DIFF_FILE="$diff_file" \
    FM_TEST_FLAG_LOG="$flag_log" FM_TEST_MODE_LOG="$mode_log" \
    "$LINT" --telemetry "$telemetry" 2>&1) \
    || fail "changed-mode local lint failed"$'\n'"$out"
  [ "$(cat "$log")" = "$target" ] \
    || fail "changed-mode lint did not run ShellCheck on exactly the changed file"$'\n'"logged: $(cat "$log")"
  [ "$(cat "$mode_log")" = on ] \
    || fail "changed-mode local lint disabled dataflow analysis"
  fm_lint_assert_flag_log "$flag_log" no "SC1091,SC2034,SC2153,SC2329"
  assert_contains "$out" "source following disabled" \
    "changed-mode local lint did not disclose dropped source following"
  assert_grep $'analysis_mode\tlocal' "$telemetry" \
    "telemetry did not record local analysis mode"
  assert_grep $'source_directives\t6' "$telemetry" \
    "telemetry did not count the changed root's source directives"
  assert_grep $'source_followed_directives\t0' "$telemetry" \
    "telemetry reported followed sources in no-external-sources mode"
  pass "fm-lint.sh changed mode drops source following and excludes cross-file codes"
}

test_changed_mode_invokes_shellcheck_once_per_root() {
  local tmp fakebin log flag_log diff_file out first second invocation_count
  tmp=$(fm_test_tmproot fm-lint-local-per-root)
  fakebin=$(fm_fakebin "$tmp")
  fm_lint_stub_git "$fakebin"
  log="$tmp/shellcheck.log"
  flag_log="$tmp/flags.log"
  fm_lint_stub_shellcheck "$fakebin" "$log"
  diff_file="$tmp/diff.nul"
  first="bin/fm-afk-launch.sh"
  # Pick two entrypoints that nothing else `# shellcheck source=`s: a sourced
  # helper would upgrade this pair to the full canonical set.
  second="bin/fm-on.sh"
  fm_lint_write_diff_file "$diff_file" "$first" "$second"

  out=$(PATH="$fakebin:$PATH" GITHUB_ACTIONS='' CI='' FM_LINT_JOBS=1 \
    FM_TEST_GIT_BRANCH=feature FM_TEST_GIT_DIFF_FILE="$diff_file" \
    FM_TEST_FLAG_LOG="$flag_log" "$LINT" 2>&1) \
    || fail "changed-mode per-root lint failed"$'\n'"$out"
  [ "$(LC_ALL=C sort "$log")" = "$first"$'\n'"$second" ] \
    || fail "changed-mode lint did not analyze both changed roots"$'\n'"logged: $(cat "$log")"
  invocation_count=$(grep -c '^external-sources=' "$flag_log" || true)
  [ "$invocation_count" -eq 2 ] \
    || fail "changed-mode lint used $invocation_count ShellCheck calls for two roots"
  fm_lint_assert_flag_log "$flag_log" no "SC1091,SC2034,SC2153,SC2329"
  pass "fm-lint.sh changed mode invokes ShellCheck once per root"
}

test_ci_keeps_external_sources_without_local_exclusions() {
  local tmp fakebin log flag_log mode_log fixture out
  tmp=$(fm_test_tmproot fm-lint-ci-follow)
  fakebin=$(fm_fakebin "$tmp")
  fixture="$tmp/fixture.sh"
  log="$tmp/shellcheck.log"
  flag_log="$tmp/flags.log"
  mode_log="$tmp/mode.log"
  cat > "$fixture" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${1:-ok}"
SH
  fm_lint_stub_shellcheck "$fakebin" "$log"

  out=$(PATH="$fakebin:$PATH" CI=true GITHUB_ACTIONS=true FM_LINT_JOBS=1 \
    FM_TEST_FLAG_LOG="$flag_log" FM_TEST_MODE_LOG="$mode_log" \
    "$LINT" "$fixture" 2>&1) \
    || fail "CI lint with explicit path failed"$'\n'"$out"
  [ "$(cat "$mode_log")" = on ] \
    || fail "CI lint disabled dataflow analysis"
  fm_lint_assert_flag_log "$flag_log" yes none
  pass "fm-lint.sh CI keeps source following without the local exclusion list"
}

test_main_branch_keeps_external_sources() {
  local tmp fakebin log flag_log out
  tmp=$(fm_test_tmproot fm-lint-main-follow)
  fakebin=$(fm_fakebin "$tmp")
  fm_lint_stub_git "$fakebin"
  log="$tmp/shellcheck.log"
  flag_log="$tmp/flags.log"
  fm_lint_stub_shellcheck "$fakebin" "$log"

  out=$(PATH="$fakebin:$PATH" GITHUB_ACTIONS='' CI='' FM_LINT_JOBS=1 \
    FM_TEST_GIT_BRANCH=main \
    FM_TEST_FLAG_LOG="$flag_log" "$LINT" 2>&1) \
    || fail "main-branch lint failed"$'\n'"$out"
  fm_lint_assert_flag_log "$flag_log" yes none
  pass "fm-lint.sh on main keeps source following without the local exclusion list"
}

test_merge_base_less_keeps_external_sources() {
  local tmp fakebin log flag_log out
  tmp=$(fm_test_tmproot fm-lint-nomergebase-follow)
  fakebin=$(fm_fakebin "$tmp")
  fm_lint_stub_git "$fakebin"
  log="$tmp/shellcheck.log"
  flag_log="$tmp/flags.log"
  fm_lint_stub_shellcheck "$fakebin" "$log"

  out=$(PATH="$fakebin:$PATH" GITHUB_ACTIONS='' CI='' FM_LINT_JOBS=1 \
    FM_TEST_GIT_BRANCH=feature FM_TEST_GIT_MERGE_BASE_OK=0 \
    FM_TEST_FLAG_LOG="$flag_log" "$LINT" 2>&1) \
    || fail "merge-base-less lint failed"$'\n'"$out"
  fm_lint_assert_flag_log "$flag_log" yes none
  pass "fm-lint.sh without a merge-base keeps source following without the local exclusion list"
}

test_explicit_path_keeps_external_sources() {
  local tmp fakebin log flag_log out target
  tmp=$(fm_test_tmproot fm-lint-explicit-follow)
  fakebin=$(fm_fakebin "$tmp")
  fm_lint_stub_git "$fakebin"
  log="$tmp/shellcheck.log"
  flag_log="$tmp/flags.log"
  fm_lint_stub_shellcheck "$fakebin" "$log"
  target="bin/fm-install-shellcheck.sh"

  out=$(PATH="$fakebin:$PATH" GITHUB_ACTIONS='' CI='' FM_LINT_JOBS=1 \
    FM_TEST_GIT_BRANCH=feature \
    FM_TEST_FLAG_LOG="$flag_log" "$LINT" "$target" 2>&1) \
    || fail "explicit-path lint failed"$'\n'"$out"
  fm_lint_assert_flag_log "$flag_log" yes none
  pass "fm-lint.sh explicit paths keep source following"
}

test_fast_mode_on_a_local_branch_keeps_source_following() {
  local tmp fakebin log flag_log mode_log diff_file out target
  tmp=$(fm_test_tmproot fm-lint-fast-follow)
  fakebin=$(fm_fakebin "$tmp")
  fm_lint_stub_git "$fakebin"
  log="$tmp/shellcheck.log"
  flag_log="$tmp/flags.log"
  mode_log="$tmp/mode.log"
  fm_lint_stub_shellcheck "$fakebin" "$log"
  diff_file="$tmp/diff.nul"
  target="bin/fm-afk-launch.sh"
  fm_lint_write_diff_file "$diff_file" "$target"

  out=$(PATH="$fakebin:$PATH" GITHUB_ACTIONS='' CI='' FM_LINT_JOBS=1 \
    FM_TEST_GIT_BRANCH=feature \
    FM_TEST_GIT_DIFF_FILE="$diff_file" \
    FM_TEST_FLAG_LOG="$flag_log" FM_TEST_MODE_LOG="$mode_log" \
    "$LINT" --fast 2>&1) \
    || fail "fast local-branch lint failed"$'\n'"$out"
  [ "$(cat "$mode_log")" = off ] \
    || fail "fast local-branch lint did not disable extended analysis"
  fm_lint_assert_flag_log "$flag_log" yes none
  pass "fm-lint.sh --fast on a local branch keeps source following"
}

test_changed_mode_hides_cross_file_codes_that_ci_still_sees() {
  if ! pinned_ready; then
    pass "SKIP (ShellCheck $REQUIRED not resolved): changed-mode exclusion behavior"
    return
  fi
  local tmp fakebin diff_file fixture out rc test_root lint
  tmp=$(fm_test_tmproot fm-lint-local-exclude-behavior)
  test_root="$tmp/repo"
  mkdir -p "$test_root/bin/backends" "$test_root/tests" "$test_root/.github/workflows"
  lint="$test_root/bin/fm-lint.sh"
  cp "$LINT" "$lint"
  cp "$ROOT/bin/fm-lint-workflows.sh" "$test_root/bin/"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$test_root/bin/fm-instruction-size-check.sh" && chmod +x "$test_root/bin/fm-instruction-size-check.sh"
  cp "$ROOT"/.github/workflows/* "$test_root/.github/workflows/"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$test_root/bin/backends/noop.sh"
  fixture="$test_root/tests/fm-lint-local-exclude-fixture.test.sh"
  cat > "$fixture" <<'SH'
#!/usr/bin/env bash
# Assigned here and only consumed by a library the local gate does not follow.
cross_file_only=1
outer() {
  (
    # Defined here and only invoked by a library the local gate does not follow.
    cross_file_helper() {
      printf 'ok\n'
    }
    printf 'hi\n'
  )
}
outer
SH
  fakebin=$(fm_fakebin "$tmp")
  fm_lint_stub_git "$fakebin"
  diff_file="$tmp/diff.nul"
  fm_lint_write_diff_file "$diff_file" "tests/fm-lint-local-exclude-fixture.test.sh"

  rc=0
  out=$(PATH="$fakebin:$PATH" GITHUB_ACTIONS='' CI='' FM_LINT_JOBS=1 \
    FM_TEST_GIT_BRANCH=feature \
    FM_TEST_GIT_DIFF_FILE="$diff_file" "$lint" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] \
    || fail "changed-mode local lint failed a cross-file-only fixture"$'\n'"$out"
  assert_not_contains "$out" "SC2034" "changed-mode local lint still reported SC2034"
  assert_not_contains "$out" "SC2329" "changed-mode local lint still reported SC2329"

  rc=0
  out=$("$lint" "$fixture" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "explicit-path lint passed a cross-file-only fixture"$'\n'"$out"
  assert_contains "$out" "SC2034" "explicit-path lint did not keep SC2034"
  assert_contains "$out" "SC2329" "explicit-path lint did not keep SC2329"
  rm -f "$fixture"
  pass "fm-lint.sh changed mode excludes cross-file codes that explicit paths still report"
}

# One ShellCheck process per root. Passing the whole canonical set in a
# single invocation still follows in-set sources and is not the no-x posture.
fm_lint_nox_one_root() {
  local index=$1 path=$2 outdir=$3
  shellcheck --norc --format gcc -- "$path" > "$outdir/$index" || true
}

test_changed_flag_keeps_source_following_in_ci() {
  local tmp fakebin log flag_log mode_log diff_file out target
  tmp=$(fm_test_tmproot fm-lint-changed-flag)
  fakebin=$(fm_fakebin "$tmp")
  fm_lint_stub_git "$fakebin"
  log="$tmp/shellcheck.log"
  flag_log="$tmp/flags.log"
  mode_log="$tmp/mode.log"
  fm_lint_stub_shellcheck "$fakebin" "$log"
  diff_file="$tmp/diff.nul"
  target="bin/fm-afk-launch.sh"
  fm_lint_write_diff_file "$diff_file" "$target" "README.md"

  out=$(PATH="$fakebin:$PATH" CI=true GITHUB_ACTIONS=true FM_LINT_JOBS=1 \
    FM_TEST_GIT_BRANCH=feature \
    FM_TEST_GIT_DIFF_FILE="$diff_file" \
    FM_TEST_FLAG_LOG="$flag_log" FM_TEST_MODE_LOG="$mode_log" \
    "$LINT" --changed --partition 1of4 2>&1) \
    || fail "CI --changed lint failed"$'\n'"$out"
  [ "$(cat "$log")" = "$target" ] \
    || fail "CI --changed did not lint exactly the changed canonical file"$'\n'"logged: $(cat "$log")"
  [ "$(cat "$mode_log")" = on ] \
    || fail "CI --changed disabled dataflow analysis"
  fm_lint_assert_flag_log "$flag_log" yes none
  pass "fm-lint.sh --changed in CI keeps source-aware analysis on the changed set"
}

test_changed_flag_upgrades_when_lint_definition_changes() {
  local tmp fakebin listed expected diff_file out
  tmp=$(fm_test_tmproot fm-lint-changed-upgrade)
  fakebin=$(fm_fakebin "$tmp")
  fm_lint_stub_git "$fakebin"
  diff_file="$tmp/diff.nul"
  fm_lint_write_diff_file "$diff_file" "bin/fm-lint.sh" "README.md"
  expected=$(find bin bin/backends tests -maxdepth 1 -type f -name '*.sh' ! -name '.*' -print | LC_ALL=C sort)

  listed=$(PATH="$fakebin:$PATH" CI=true GITHUB_ACTIONS=true \
    FM_TEST_GIT_BRANCH=feature FM_TEST_GIT_DIFF_FILE="$diff_file" \
    "$LINT" --changed --list-files 2>"$tmp/err")
  [ "$(printf '%s\n' "$listed" | LC_ALL=C sort)" = "$expected" ] \
    || fail "--changed did not upgrade to the full canonical set when lint tooling changed"
  assert_contains "$(cat "$tmp/err")" "lint definition files changed" \
    "--changed upgrade did not explain why it used the full set"
  pass "fm-lint.sh --changed upgrades to full lint when lint definition files change"
}

test_empty_changed_partition_is_a_successful_noop() {
  local tmp fakebin diff_file out rc telemetry roots_log
  tmp=$(fm_test_tmproot fm-lint-empty-partition)
  fakebin=$(fm_fakebin "$tmp")
  fm_lint_stub_git "$fakebin"
  fm_lint_stub_shellcheck "$fakebin" "$tmp/shellcheck.log"
  diff_file="$tmp/diff.nul"
  telemetry="$tmp/partition-2.tsv"
  roots_log="$tmp/partition-2.roots.tsv"
  fm_lint_write_diff_file "$diff_file" "bin/fm-afk-launch.sh"

  rc=0
  out=$(PATH="$fakebin:$PATH" CI=true GITHUB_ACTIONS=true FM_LINT_JOBS=1 \
    FM_TEST_GIT_BRANCH=feature FM_TEST_GIT_DIFF_FILE="$diff_file" \
    "$LINT" --changed --partition 2of4 --telemetry "$telemetry" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "an empty changed partition must exit 0, got $rc"$'\n'"$out"
  assert_contains "$out" "no lint targets in this partition" \
    "empty changed partition did not note the empty target set"
  [ ! -s "$tmp/shellcheck.log" ] || fail "empty partition invoked ShellCheck"
  [ -f "$telemetry" ] || fail "empty partition wrote no --telemetry snapshot"$'\n'"$out"
  assert_grep $'format\tfm-lint-telemetry-v1' "$telemetry" \
    "empty partition telemetry omitted the format marker"
  assert_grep $'root_count\t0' "$telemetry" \
    "empty partition telemetry did not record root_count=0"
  assert_grep $'partition\t2of4' "$telemetry" \
    "empty partition telemetry did not record its partition"
  assert_grep $'wall_seconds\t' "$telemetry" \
    "empty partition telemetry omitted wall_seconds"
  [ -f "$roots_log" ] || fail "empty partition wrote no roots sidecar beside telemetry"
  pass "fm-lint.sh treats an empty --changed partition as a successful no-op that still writes telemetry"
}

test_changed_flag_upgrades_when_a_sourced_helper_changes() {
  local tmp fakebin listed expected diff_file out
  tmp=$(fm_test_tmproot fm-lint-sourced-helper)
  fakebin=$(fm_fakebin "$tmp")
  fm_lint_stub_git "$fakebin"
  diff_file="$tmp/diff.nul"
  fm_lint_write_diff_file "$diff_file" "bin/fm-wake-lib.sh" "README.md"
  expected=$(find bin bin/backends tests -maxdepth 1 -type f -name '*.sh' ! -name '.*' -print | LC_ALL=C sort)

  listed=$(PATH="$fakebin:$PATH" CI=true GITHUB_ACTIONS=true \
    FM_TEST_GIT_BRANCH=feature FM_TEST_GIT_DIFF_FILE="$diff_file" \
    "$LINT" --changed --list-files 2>"$tmp/err")
  [ "$(printf '%s\n' "$listed" | LC_ALL=C sort)" = "$expected" ] \
    || fail "--changed did not upgrade to the full canonical set when a sourced helper changed"
  assert_contains "$(cat "$tmp/err")" "a sourced helper changed" \
    "--changed upgrade did not explain why a sourced helper used the full set"
  pass "fm-lint.sh --changed upgrades to full lint when a sourced helper changes"
}

test_changed_flag_upgrades_when_a_sourced_helper_is_deleted() {
  local tmp fakebin listed expected status_file
  tmp=$(fm_test_tmproot fm-lint-deleted-helper)
  fakebin=$(fm_fakebin "$tmp")
  fm_lint_stub_git "$fakebin"
  status_file="$tmp/name-status"
  fm_lint_write_name_status "$status_file" $'D\tbin/fm-wake-lib.sh' $'M\tREADME.md'
  expected=$(find bin bin/backends tests -maxdepth 1 -type f -name '*.sh' ! -name '.*' -print | LC_ALL=C sort)

  listed=$(PATH="$fakebin:$PATH" CI=true GITHUB_ACTIONS=true \
    FM_TEST_GIT_BRANCH=feature FM_TEST_GIT_NAME_STATUS_FILE="$status_file" \
    "$LINT" --changed --list-files 2>"$tmp/err")
  [ "$(printf '%s\n' "$listed" | LC_ALL=C sort)" = "$expected" ] \
    || fail "--changed did not upgrade to the full canonical set when a sourced helper was deleted"
  assert_contains "$(cat "$tmp/err")" "a sourced helper changed" \
    "--changed upgrade did not explain why a deleted sourced helper used the full set"
  pass "fm-lint.sh --changed upgrades to full lint when a sourced helper is deleted"
}

test_changed_flag_upgrades_when_a_sourced_helper_is_renamed() {
  local tmp fakebin listed expected status_file
  tmp=$(fm_test_tmproot fm-lint-renamed-helper)
  fakebin=$(fm_fakebin "$tmp")
  fm_lint_stub_git "$fakebin"
  status_file="$tmp/name-status"
  fm_lint_write_name_status "$status_file" \
    $'R100\tbin/fm-wake-lib.sh\tbin/fm-wake-lib-moved.sh'
  expected=$(find bin bin/backends tests -maxdepth 1 -type f -name '*.sh' ! -name '.*' -print | LC_ALL=C sort)

  listed=$(PATH="$fakebin:$PATH" CI=true GITHUB_ACTIONS=true \
    FM_TEST_GIT_BRANCH=feature FM_TEST_GIT_NAME_STATUS_FILE="$status_file" \
    "$LINT" --changed --list-files 2>"$tmp/err")
  [ "$(printf '%s\n' "$listed" | LC_ALL=C sort)" = "$expected" ] \
    || fail "--changed did not upgrade to the full canonical set when a sourced helper was renamed"
  assert_contains "$(cat "$tmp/err")" "a sourced helper changed" \
    "--changed upgrade did not explain why a renamed sourced helper used the full set"
  pass "fm-lint.sh --changed upgrades to full lint when a sourced helper is renamed"
}

test_changed_flag_upgrades_when_a_lint_definition_is_renamed() {
  local tmp fakebin listed expected status_file
  tmp=$(fm_test_tmproot fm-lint-renamed-definition)
  fakebin=$(fm_fakebin "$tmp")
  fm_lint_stub_git "$fakebin"
  status_file="$tmp/name-status"
  fm_lint_write_name_status "$status_file" \
    $'R100\tbin/fm-timeout-lib.sh\tbin/fm-timeout-lib-moved.sh' $'M\tREADME.md'
  expected=$(find bin bin/backends tests -maxdepth 1 -type f -name '*.sh' ! -name '.*' -print | LC_ALL=C sort)

  listed=$(PATH="$fakebin:$PATH" CI=true GITHUB_ACTIONS=true \
    FM_TEST_GIT_BRANCH=feature FM_TEST_GIT_NAME_STATUS_FILE="$status_file" \
    "$LINT" --changed --list-files 2>"$tmp/err")
  [ "$(printf '%s\n' "$listed" | LC_ALL=C sort)" = "$expected" ] \
    || fail "--changed did not upgrade to the full canonical set when a lint definition file was renamed"
  assert_contains "$(cat "$tmp/err")" "lint definition files changed" \
    "--changed upgrade did not explain why a renamed lint definition used the full set"
  pass "fm-lint.sh --changed upgrades to full lint when a lint definition file is renamed"
}

test_installer_skips_download_when_pinned_binary_is_present() {
  local tmp fakebin destination out
  tmp=$(fm_test_tmproot fm-shellcheck-cached)
  fakebin=$(fm_fakebin "$tmp")
  destination="$tmp/bin"
  mkdir -p "$destination"
  fm_install_stub_uname "$fakebin"
  fm_install_stub_curl "$fakebin"
  cat > "$destination/shellcheck" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --version ]; then
  printf 'ShellCheck - shell script analysis tool\nversion: ${REQUIRED}\n'
  exit 0
fi
exit 0
SH
  chmod +x "$destination/shellcheck"

  out=$(CURL_COUNT="$tmp/curl-count" \
    FM_TEST_UNAME_S=Linux FM_TEST_UNAME_M=x86_64 \
    PATH="$fakebin:$PATH" "$INSTALLER" "$destination" 2>&1) \
    || fail "installer failed to reuse a pinned ShellCheck"$'\n'"$out"
  assert_contains "$out" "already at" "installer did not skip a present pinned binary"
  [ ! -f "$tmp/curl-count" ] || fail "installer downloaded ShellCheck even though the pin was already present"
  pass "ShellCheck installer skips download when the pinned binary is already present"
}

test_local_exclusion_list_covers_every_no_external_sources_code() {
  if ! pinned_ready; then
    pass "SKIP (ShellCheck $REQUIRED not resolved): local exclusion completeness"
    return
  fi
  local tmp files_file out unexpected code path found i batch
  local -a files
  tmp=$(fm_test_tmproot fm-lint-nox-complete)
  files_file="$tmp/files"
  CI=true "$LINT" --list-files > "$files_file"
  [ -s "$files_file" ] || fail "CI --list-files returned no canonical lint roots"
  files=()
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    files+=("$path")
  done < "$files_file"
  [ "${#files[@]}" -gt 0 ] || fail "CI --list-files returned no readable lint roots"
  mkdir -p "$tmp/gcc"
  i=0
  batch=0
  for path in "${files[@]}"; do
    i=$((i + 1))
    fm_lint_nox_one_root "$i" "$path" "$tmp/gcc" &
    batch=$((batch + 1))
    if [ "$batch" -eq 4 ]; then
      wait
      batch=0
    fi
  done
  wait
  found=$(find "$tmp/gcc" -type f | wc -l | tr -d '[:space:]')
  [ "$found" = "${#files[@]}" ] \
    || fail "completeness sweep linted $found roots, expected ${#files[@]}"
  out=$(cat "$tmp/gcc"/* 2>/dev/null || true)
  unexpected=
  while IFS= read -r code; do
    [ -n "$code" ] || continue
    case "$code" in
      SC1091|SC2034|SC2153|SC2329) ;;
      *) unexpected="${unexpected}${unexpected:+ }$code" ;;
    esac
  done < <(printf '%s\n' "$out" | sed -n 's/.*\[\(SC[0-9][0-9]*\)\].*/\1/p' | LC_ALL=C sort -u)
  [ -z "$unexpected" ] \
    || fail "no-external-sources pass emitted codes outside the local exclusion list: $unexpected"
  pass "local exclusion list covers every no-external-sources ShellCheck code"
}

test_pins_an_explicit_version() {
  [ -n "$REQUIRED" ] || fail "fm-lint.sh --required-version printed nothing"
  # The captain-agreed pin: adopt ShellCheck 0.11.0's rule set consistently,
  # which is also what drops the upstream-retired, false-positive-prone SC2015.
  assert_contains "$REQUIRED" "0.11.0" "fm-lint.sh must pin ShellCheck 0.11.0"
  pass "fm-lint.sh pins an explicit ShellCheck version ($REQUIRED)"
}

test_installer_retries_transient_download_failure() {
  local tmp fakebin destination out
  tmp=$(fm_test_tmproot fm-shellcheck-download)
  fakebin=$(fm_fakebin "$tmp")
  destination="$tmp/bin"

  fm_install_stub_uname "$fakebin"
  fm_install_stub_curl "$fakebin"
  fm_install_stub_hasher "$fakebin" sha256sum
  fm_install_stub_tar_shellcheck "$fakebin"
  fm_install_stub_sleep "$fakebin"

  # Reproduce the CI incident: the release endpoint returned 503 for all three
  # formerly configured attempts before recovering. Force linux/x86_64 so the
  # retry path stays the CI archive even when this suite runs on macOS.
  out=$(CURL_COUNT="$tmp/curl-count" CURL_FAIL_UNTIL=3 \
    SHA256_STUB_HASH="$SHELLCHECK_SHA_LINUX_X86_64" \
    FM_TEST_UNAME_S=Linux FM_TEST_UNAME_M=x86_64 \
    PATH="$fakebin:$PATH" "$INSTALLER" "$destination" 2>&1) \
    || fail "installer did not recover from a transient download failure"$'\n'"$out"
  [ "$(cat "$tmp/curl-count")" -eq 4 ] || fail "installer did not recover after three failed downloads"
  assert_contains "$out" "download attempt 3 failed; retrying" "installer did not disclose its third retry"
  [ -x "$destination/shellcheck" ] || fail "installer did not install ShellCheck after retrying"
  pass "ShellCheck installer retries a transient download failure"
}

test_installer_selects_platform_archive_url_and_checksum() {
  local tmp fakebin destination out url_log uname_s uname_m archive sha
  tmp=$(fm_test_tmproot fm-shellcheck-platform)
  fakebin=$(fm_fakebin "$tmp")
  destination="$tmp/bin"
  url_log="$tmp/curl-url.log"

  fm_install_stub_uname "$fakebin"
  fm_install_stub_curl "$fakebin"
  fm_install_stub_hasher "$fakebin" sha256sum
  fm_install_stub_tar_shellcheck "$fakebin"
  fm_install_stub_sleep "$fakebin"

  while IFS=$'\t' read -r uname_s uname_m archive sha; do
    [ -n "$uname_s" ] || continue
    rm -rf "$destination"
    : > "$url_log"
    out=$(CURL_URL_LOG="$url_log" SHA256_STUB_HASH="$sha" \
      FM_TEST_UNAME_S="$uname_s" FM_TEST_UNAME_M="$uname_m" \
      PATH="$fakebin:$PATH" "$INSTALLER" "$destination" 2>&1) \
      || fail "installer failed for ${uname_s}/${uname_m}"$'\n'"$out"
    assert_contains "$(cat "$url_log")" "$archive" \
      "installer did not download $archive for ${uname_s}/${uname_m}"
    assert_contains "$(cat "$url_log")" \
      "https://github.com/koalaman/shellcheck/releases/download/v${REQUIRED}/${archive}" \
      "installer used the wrong URL for ${uname_s}/${uname_m}"
    [ -x "$destination/shellcheck" ] || fail "installer did not install ShellCheck for ${uname_s}/${uname_m}"
  done <<EOF
Linux	x86_64	shellcheck-v${REQUIRED}.linux.x86_64.tar.xz	$SHELLCHECK_SHA_LINUX_X86_64
Linux	amd64	shellcheck-v${REQUIRED}.linux.x86_64.tar.xz	$SHELLCHECK_SHA_LINUX_X86_64
Linux	aarch64	shellcheck-v${REQUIRED}.linux.aarch64.tar.xz	$SHELLCHECK_SHA_LINUX_AARCH64
Linux	arm64	shellcheck-v${REQUIRED}.linux.aarch64.tar.xz	$SHELLCHECK_SHA_LINUX_AARCH64
Darwin	x86_64	shellcheck-v${REQUIRED}.darwin.x86_64.tar.xz	$SHELLCHECK_SHA_DARWIN_X86_64
Darwin	amd64	shellcheck-v${REQUIRED}.darwin.x86_64.tar.xz	$SHELLCHECK_SHA_DARWIN_X86_64
Darwin	arm64	shellcheck-v${REQUIRED}.darwin.aarch64.tar.xz	$SHELLCHECK_SHA_DARWIN_AARCH64
Darwin	aarch64	shellcheck-v${REQUIRED}.darwin.aarch64.tar.xz	$SHELLCHECK_SHA_DARWIN_AARCH64
EOF
  pass "ShellCheck installer selects the official archive, URL, and checksum per OS/arch"
}

test_installer_rejects_wrong_checksum() {
  local tmp fakebin destination out rc
  tmp=$(fm_test_tmproot fm-shellcheck-badsum)
  fakebin=$(fm_fakebin "$tmp")
  destination="$tmp/bin"

  fm_install_stub_uname "$fakebin"
  fm_install_stub_curl "$fakebin"
  fm_install_stub_hasher "$fakebin" sha256sum
  fm_install_stub_tar_shellcheck "$fakebin"
  fm_install_stub_sleep "$fakebin"

  rc=0
  out=$(SHA256_STUB_HASH=0000000000000000000000000000000000000000000000000000000000000000 \
    FM_TEST_UNAME_S=Linux FM_TEST_UNAME_M=x86_64 \
    PATH="$fakebin:$PATH" "$INSTALLER" "$destination" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "installer accepted a wrong checksum"$'\n'"$out"
  assert_contains "$out" "checksum mismatch" "installer did not report a checksum mismatch"
  assert_contains "$out" "shellcheck-v${REQUIRED}.linux.x86_64.tar.xz" \
    "mismatch did not name the selected archive"
  assert_contains "$out" "$SHELLCHECK_SHA_LINUX_X86_64" \
    "mismatch did not name the pinned linux/x86_64 checksum"
  [ ! -e "$destination/shellcheck" ] || fail "installer installed ShellCheck after a checksum mismatch"
  pass "ShellCheck installer rejects a wrong checksum"
}

test_installer_falls_back_to_shasum() {
  local tmp fakebin destination out hasher_log tool
  tmp=$(fm_test_tmproot fm-shellcheck-shasum)
  fakebin=$(fm_fakebin "$tmp")
  destination="$tmp/bin"
  hasher_log="$tmp/hasher.log"

  for tool in bash dirname mktemp rm awk mkdir install cat chmod; do
    ln -s "$(command -v "$tool")" "$fakebin/$tool"
  done
  fm_install_stub_uname "$fakebin"
  fm_install_stub_curl "$fakebin"
  fm_install_stub_hasher "$fakebin" shasum
  fm_install_stub_tar_shellcheck "$fakebin"
  fm_install_stub_sleep "$fakebin"

  # Restricted PATH: shasum is present, sha256sum is not.
  : > "$hasher_log"
  out=$(CURL_URL_LOG="$tmp/curl-url.log" HASHER_LOG="$hasher_log" \
    SHA256_STUB_HASH="$SHELLCHECK_SHA_LINUX_X86_64" \
    FM_TEST_UNAME_S=Linux FM_TEST_UNAME_M=x86_64 \
    PATH="$fakebin" "$INSTALLER" "$destination" 2>&1) \
    || fail "installer did not fall back to shasum -a 256"$'\n'"$out"
  assert_grep 'shasum -a 256' "$hasher_log" "installer did not invoke shasum -a 256"
  [ -x "$destination/shellcheck" ] || fail "installer did not install ShellCheck via shasum"
  pass "ShellCheck installer falls back to shasum -a 256 when sha256sum is absent"
}

test_installer_prefers_sha256sum_over_shasum() {
  local tmp fakebin destination hasher_log
  tmp=$(fm_test_tmproot fm-shellcheck-sha256sum-pref)
  fakebin=$(fm_fakebin "$tmp")
  destination="$tmp/bin"
  hasher_log="$tmp/hasher.log"

  fm_install_stub_uname "$fakebin"
  fm_install_stub_curl "$fakebin"
  fm_install_stub_hasher "$fakebin" sha256sum
  fm_install_stub_hasher "$fakebin" shasum
  fm_install_stub_tar_shellcheck "$fakebin"
  fm_install_stub_sleep "$fakebin"

  : > "$hasher_log"
  PATH="$fakebin:$PATH" HASHER_LOG="$hasher_log" \
    SHA256_STUB_HASH="$SHELLCHECK_SHA_LINUX_X86_64" \
    FM_TEST_UNAME_S=Linux FM_TEST_UNAME_M=x86_64 \
    "$INSTALLER" "$destination" >/dev/null \
    || fail "installer failed when both hashers were present"
  assert_grep 'sha256sum' "$hasher_log" "installer did not prefer sha256sum"
  if grep -q 'shasum' "$hasher_log"; then
    fail "installer invoked shasum even though sha256sum was present"$'\n'"$(cat "$hasher_log")"
  fi
  pass "ShellCheck installer prefers sha256sum when both hashers are present"
}

test_installer_rejects_unsupported_platform() {
  local tmp fakebin destination out rc
  tmp=$(fm_test_tmproot fm-shellcheck-unsupported)
  fakebin=$(fm_fakebin "$tmp")
  destination="$tmp/bin"

  fm_install_stub_uname "$fakebin"
  fm_install_stub_curl "$fakebin"

  rc=0
  out=$(FM_TEST_UNAME_S=FreeBSD FM_TEST_UNAME_M=amd64 \
    PATH="$fakebin:$PATH" "$INSTALLER" "$destination" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "installer accepted an unsupported OS"$'\n'"$out"
  assert_contains "$out" "unsupported platform" "installer did not name the unsupported platform"
  assert_contains "$out" "FreeBSD-amd64" "installer did not report the detected OS/arch"

  rc=0
  out=$(FM_TEST_UNAME_S=Linux FM_TEST_UNAME_M=ppc64le \
    PATH="$fakebin:$PATH" "$INSTALLER" "$destination" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "installer accepted an unsupported architecture"$'\n'"$out"
  assert_contains "$out" "unsupported platform" "installer did not reject linux/ppc64le"
  pass "ShellCheck installer rejects an unsupported OS or architecture"
}

test_missing_shellcheck_fails_closed() {
  local tmp fakebin out rc tool
  tmp=$(fm_test_tmproot fm-lint-noshellcheck)
  fakebin=$(fm_fakebin "$tmp")
  for tool in bash dirname; do
    ln -s "$(command -v "$tool")" "$fakebin/$tool"
  done
  rc=0
  out=$(PATH="$fakebin" CI=true GITHUB_ACTIONS=true "$LINT" 2>&1) || rc=$?
  [ "$rc" -eq 1 ] || fail "missing ShellCheck expected exit 1, got $rc"$'\n'"$out"
  assert_contains "$out" "ShellCheck not found" \
    "missing ShellCheck did not name the required linter"
  assert_contains "$out" "$REQUIRED" \
    "missing ShellCheck did not name the pinned version"
  assert_contains "$out" "fm-install-shellcheck.sh" \
    "missing ShellCheck did not name the pinned installer"
  pass "missing ShellCheck fails closed"
}

test_rejects_wrong_shellcheck_version() {
  # Version-independent: a fake shellcheck reporting a different version must be
  # refused before any lint, proving local and CI cannot silently diverge.
  local tmp fakebin out rc
  tmp=$(fm_test_tmproot fm-lint-ver)
  fakebin=$(fm_fakebin "$tmp")
  cat > "$fakebin/shellcheck" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "--version" ]; then
  printf 'ShellCheck - shell script analysis tool\nversion: 0.9.9\nlicense: x\nwebsite: y\n'
  exit 0
fi
case " $* " in *" --include="*) exit 0 ;; esac
exit 0
SH
  chmod +x "$fakebin/shellcheck"
  rc=0
  out=$(PATH="$fakebin:$PATH" "$LINT" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "fm-lint.sh accepted a shellcheck version other than the pin"$'\n'"$out"
  assert_contains "$out" "$REQUIRED" "fm-lint.sh did not name the required version on mismatch"
  assert_contains "$out" "0.9.9" "fm-lint.sh did not report the resolved (wrong) version"
  pass "fm-lint.sh refuses to lint under a non-pinned ShellCheck version"
}

test_catches_a_real_lint_defect() {
  if ! pinned_ready; then
    pass "SKIP (ShellCheck $REQUIRED not resolved): lint-defect regression check"
    return
  fi
  # A script with a genuine ShellCheck finding must make the one owner exit
  # non-zero, proving local now runs real shellcheck instead of the old no-op
  # lint step. We deliberately do NOT assert SC2015 (PR 475's actual failure):
  # ShellCheck removed SC2015 in the pinned 0.11.0, so asserting it would make
  # this test itself version-fragile - the very trap being fixed. SC1007 is a
  # warning present at default severity (and is itself one of the recurring
  # classes that slipped through, PR 474).
  local tmp bad out rc
  tmp=$(fm_test_tmproot fm-lint-bad)
  mkdir -p "$tmp"
  bad="$tmp/bad.sh"
  cat > "$bad" <<'SH'
#!/usr/bin/env bash
foo() {
  local a= b=
  echo "$a$b"
}
foo
SH
  rc=0
  out=$("$LINT" "$bad" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "fm-lint.sh passed a known-bad fixture"$'\n'"$out"
  assert_contains "$out" "SC1007" "fm-lint.sh did not report the expected ShellCheck finding"
  pass "fm-lint.sh catches a real lint defect the old no-op gate passed"
}

test_rejects_direct_beads_cli_invocations() {
  local tmp fakebin log lint_copy invocation out rc
  tmp=$(fm_test_tmproot fm-lint-backend-purity)
  fakebin=$(fm_fakebin "$tmp")
  log="$tmp/shellcheck.log"
  mkdir -p "$tmp/repo/bin/backends" "$tmp/repo/tests"
  lint_copy="$tmp/repo/bin/fm-lint.sh"
  cp "$LINT" "$lint_copy"
  cat > "$tmp/repo/bin/fm-lint-workflows.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$tmp/repo/bin/backends/noop.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$tmp/repo/tests/noop.test.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$lint_copy" "$tmp/repo/bin/fm-lint-workflows.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/repo/bin/fm-instruction-size-check.sh" && chmod +x "$tmp/repo/bin/fm-instruction-size-check.sh"
  fm_lint_stub_shellcheck "$fakebin" "$log"

  for invocation in \
    'bd update fm-example --status in_progress' \
    'BD_ACTOR=firstmate bd update fm-example --status closed' \
    'env bd close fm-example' \
    'env -i BD_ACTOR=firstmate bd close fm-example' \
    'env -u BD_ACTOR bd close fm-example' \
    'env -- bd close fm-example' \
    '/usr/local/bin/bd close fm-example' \
    '"/usr/local/bin/bd" close fm-example' \
    "'/usr/local/bin/bd' close fm-example" \
    "b'd' close fm-example" \
    "/usr/local/bin/b'd' close fm-example" \
    "\$'bd' close fm-example" \
    '$"bd" close fm-example' \
    "\$'\\x62\\x64' close fm-example" \
    "\$'\\142\\144' close fm-example" \
    "b\$'\\x64' close fm-example"
  do
    printf '#!/usr/bin/env bash\n%s\n' "$invocation" > "$tmp/repo/bin/direct-beads.sh"
    rc=0
    out=$(cd "$tmp/repo" && CI=true PATH="$fakebin:$PATH" "$lint_copy" 2>&1) || rc=$?
    [ "$rc" -ne 0 ] || fail "lint accepted a direct Beads CLI invocation: $invocation"
    assert_contains "$out" "direct Beads CLI invocation bypasses tasks-axi" \
      "lint did not identify the backend-boundary violation: $invocation"
  done
  pass "fm-lint.sh rejects direct Beads CLI invocations in firstmate core"
}

test_rejects_direct_beads_cli_in_explicit_core_path() {
  local tmp fakebin log lint_copy target spelling out rc
  tmp=$(fm_test_tmproot fm-lint-explicit-backend-purity)
  fakebin=$(fm_fakebin "$tmp")
  log="$tmp/shellcheck.log"
  mkdir -p "$tmp/repo/bin/backends"
  lint_copy="$tmp/repo/bin/fm-lint.sh"
  target="$tmp/repo/bin/direct-beads.sh"
  cp "$LINT" "$lint_copy"
  printf '#!/usr/bin/env bash\nbd close fm-example\n' > "$target"
  chmod +x "$lint_copy"
  fm_lint_stub_shellcheck "$fakebin" "$log"

  for spelling in bin/direct-beads.sh bin/../bin/direct-beads.sh; do
    rc=0
    out=$(cd "$tmp/repo" && PATH="$fakebin:$PATH" "$lint_copy" "$spelling" 2>&1) || rc=$?
    [ "$rc" -ne 0 ] || fail "explicit core path bypassed backend-purity lint: $spelling"
    assert_contains "$out" "direct Beads CLI invocation bypasses tasks-axi" \
      "explicit core path did not report the backend-boundary violation: $spelling"
  done
  pass "fm-lint.sh enforces backend purity for explicit core paths"
}

# A file that fails the ratchet check (a variable that needs no quoting is left
# bare, which only the optional quote-safe-variables check flags) but passes the
# default pass, so only the ratchet can fail it.
# shellcheck disable=SC2016 # The fixture text is shell source, not expanded here.
fm_lint_ratchet_fixture() {  # <path> <passing|failing>
  if [ "$2" = failing ]; then
    printf '%s\n' '#!/usr/bin/env bash' 'foo=1' 'echo $foo' > "$1"
  else
    printf '%s\n' '#!/usr/bin/env bash' 'foo=1' 'echo "$foo"' > "$1"
  fi
}

test_ratchet_skips_listed_files_and_fails_unlisted_ones() {
  if ! pinned_ready; then
    pass "SKIP (ShellCheck $REQUIRED not resolved): ratchet regression check"
    return
  fi
  local tmp listed unlisted list out rc
  tmp=$(fm_test_tmproot fm-lint-ratchet)
  mkdir -p "$tmp/repo/bin"
  cp "$LINT" "$tmp/repo/bin/fm-lint.sh"
  listed="$tmp/repo/bin/listed.sh"
  unlisted="$tmp/repo/bin/unlisted.sh"
  list="$tmp/list"
  fm_lint_ratchet_fixture "$listed" failing
  fm_lint_ratchet_fixture "$unlisted" failing
  printf '# exceptions\nbin/listed.sh\n' > "$list"

  rc=0
  out=$(FM_LINT_RATCHET_LIST="$list" "$tmp/repo/bin/fm-lint.sh" bin/listed.sh 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "a listed failing file was not skipped by the ratchet"$'\n'"$out"

  rc=0
  out=$(FM_LINT_RATCHET_LIST="$list" "$tmp/repo/bin/fm-lint.sh" bin/unlisted.sh 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "an unlisted failing file passed the ratchet"$'\n'"$out"
  assert_contains "$out" "SC2248" "the ratchet did not report the stricter finding"
  pass "fm-lint.sh skips listed files and fails unlisted ones under the ratchet"
}

test_ratchet_reports_a_listed_file_that_now_passes() {
  if ! pinned_ready; then
    pass "SKIP (ShellCheck $REQUIRED not resolved): ratchet stale-entry check"
    return
  fi
  local tmp list out rc
  tmp=$(fm_test_tmproot fm-lint-ratchet-stale)
  mkdir -p "$tmp/repo/bin"
  cp "$LINT" "$tmp/repo/bin/fm-lint.sh"
  list="$tmp/list"
  fm_lint_ratchet_fixture "$tmp/repo/bin/fixed.sh" passing
  printf 'bin/fixed.sh\n' > "$list"
  rc=0
  out=$(FM_LINT_RATCHET_LIST="$list" "$tmp/repo/bin/fm-lint.sh" bin/fixed.sh 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a listed file that passes the ratchet was not reported"$'\n'"$out"
  assert_contains "$out" "remove it from" "the stale exception was not named"
  pass "fm-lint.sh reports a listed file that already passes the ratchet"
}

test_ratchet_tool_failure_is_not_a_stale_entry() {
  # A ratchet invocation that dies (here a stub reporting a heap exhaustion)
  # must fail lint as a tool failure; a listed file must never be called
  # stale because ShellCheck produced no findings while crashing.
  local tmp fakebin list out rc
  tmp=$(fm_test_tmproot fm-lint-ratchet-crash)
  fakebin=$(fm_fakebin "$tmp")
  mkdir -p "$tmp/repo/bin"
  cp "$LINT" "$tmp/repo/bin/fm-lint.sh"
  cp "$ROOT/bin/fm-timeout-lib.sh" "$tmp/repo/bin/"
  list="$tmp/list"
  printf '%s\n' '#!/usr/bin/env bash' 'echo hi' > "$tmp/repo/bin/listed.sh"
  printf 'bin/listed.sh\n' > "$list"
  cat > "$fakebin/shellcheck" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "--version" ]; then
  printf 'ShellCheck - shell script analysis tool\nversion: 0.11.0\n'
  exit 0
fi
case " $* " in *" --include="*) printf 'shellcheck: Heap exhausted;\n' >&2; exit 251 ;; esac
exit 0
SH
  chmod +x "$fakebin/shellcheck"
  rc=0
  out=$(PATH="$fakebin:$PATH" FM_LINT_RATCHET_LIST="$list" "$tmp/repo/bin/fm-lint.sh" bin/listed.sh 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a crashed ratchet check passed lint"$'\n'"$out"
  assert_contains "$out" "ratchet check of bin/listed.sh failed (reason=memory" \
    "the ratchet tool failure was not named"
  case "$out" in
    *"passes the ratchet check"*) fail "a crashed ratchet check reported a stale entry"$'\n'"$out" ;;
  esac
  pass "fm-lint.sh reports a crashed ratchet check as a tool failure, not a stale entry"
}

test_ratchet_shares_the_roots_one_deadline() {
  # The ratchet check spends only what the main pass left of the root's one
  # deadline: a 2s main pass under a 4s deadline leaves a hung ratchet about
  # 2s, so the root ends near 4s with a named timeout, where a fresh deadline
  # would let it run to about 6s.
  if ! fm_lint_bounds_supported; then
    pass "SKIP (bounded runs unsupported): ratchet deadline check"
    return
  fi
  local tmp fakebin out rc duration
  tmp=$(fm_test_tmproot fm-lint-ratchet-deadline)
  fakebin=$(fm_fakebin "$tmp")
  printf '%s\n' '#!/usr/bin/env bash' 'echo hi' > "$tmp/slow.sh"
  cat > "$fakebin/shellcheck" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "--version" ]; then
  printf 'ShellCheck - shell script analysis tool\nversion: 0.11.0\n'
  exit 0
fi
case " $* " in *" --include="*) sleep 30; exit 0 ;; esac
sleep 2
exit 0
SH
  chmod +x "$fakebin/shellcheck"
  rc=0
  out=$(PATH="$fakebin:$PATH" FM_LINT_JOBS=1 FM_LINT_REQUIRE_BOUNDS=1 FM_LINT_ROOT_SECONDS=4 \
    FM_LINT_ROOT_GRACE=1 "$LINT" "$tmp/slow.sh" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a hung ratchet check passed"$'\n'"$out"
  assert_contains "$out" "ratchet check of $tmp/slow.sh failed (reason=timeout" \
    "the ratchet timeout was not named"
  duration=$(printf '%s\n' "$out" | sed -n 's/^fm-lint: end .* duration_ms=\([0-9]*\) .*/\1/p')
  [ -n "$duration" ] && [ "$duration" -lt 5500 ] \
    || fail "the ratchet check got a fresh deadline (duration_ms=${duration:-none})"$'\n'"$out"
  pass "fm-lint.sh runs the ratchet check inside the root's one deadline"
}

test_ratchet_helper_retires_one_file_at_a_time() {
  if ! pinned_ready; then
    pass "SKIP (ShellCheck $REQUIRED not resolved): ratchet helper check"
    return
  fi
  local helper="$ROOT/bin/fm-lint-ratchet.sh" tmp list out rc
  tmp=$(fm_test_tmproot fm-lint-ratchet-helper)
  list="$tmp/list"
  printf '# header\nbin/fm-lint-ratchet.sh\nbin/fm-send.sh\n' > "$list"
  out=$(FM_LINT_RATCHET_LIST="$list" "$helper" next) || fail "next failed"
  [ "$out" = bin/fm-lint-ratchet.sh ] || fail "next did not print the first entry: $out"
  out=$(FM_LINT_RATCHET_LIST="$list" "$helper" count)
  [ "$out" = 2 ] || fail "count was $out, expected 2"
  rc=0
  FM_LINT_RATCHET_LIST="$list" "$helper" retire bin/not-listed.sh >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "retire accepted a file that is not on the list"
  FM_LINT_RATCHET_LIST="$list" "$helper" retire bin/fm-lint-ratchet.sh >/dev/null 2>&1 \
    || fail "retire refused a file that passes the ratchet"
  [ "$(FM_LINT_RATCHET_LIST="$list" "$helper" list)" = bin/fm-send.sh ] \
    || fail "retire did not leave exactly the other entry"
  pass "fm-lint-ratchet.sh retires one passing file at a time"
}

test_ignores_ambient_shellcheck_opts() {
  if ! pinned_ready; then
    pass "SKIP (ShellCheck $REQUIRED not resolved): ambient options regression check"
    return
  fi
  local tmp bad out rc
  tmp=$(fm_test_tmproot fm-lint-opts)
  mkdir -p "$tmp"
  bad="$tmp/bad.sh"
  cat > "$bad" <<'SH'
#!/usr/bin/env bash
foo() {
  local a= b=
  echo "$a$b"
}
foo
SH
  rc=0
  out=$(SHELLCHECK_OPTS='--exclude=SC1007' "$LINT" "$bad" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "fm-lint.sh allowed ambient SHELLCHECK_OPTS to hide a finding"$'\n'"$out"
  assert_contains "$out" "SC1007" "fm-lint.sh did not neutralize ambient SHELLCHECK_OPTS"
  pass "fm-lint.sh ignores ambient ShellCheck options"
}

test_clean_fixture_passes() {
  if ! pinned_ready; then
    pass "SKIP (ShellCheck $REQUIRED not resolved): clean fixture check"
    return
  fi
  local tmp good rc
  tmp=$(fm_test_tmproot fm-lint-good)
  mkdir -p "$tmp"
  good="$tmp/good.sh"
  cat > "$good" <<'SH'
#!/usr/bin/env bash
set -eu
if [ -n "${1:-}" ] && [ -d "$1" ]; then
  printf 'ok\n'
fi
SH
  rc=0
  "$LINT" "$good" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || fail "fm-lint.sh flagged a clean fixture (exit $rc)"
  pass "fm-lint.sh passes a clean fixture"
}

test_jobs_are_deterministic_and_complete() {
  if ! pinned_ready; then
    pass "SKIP (ShellCheck $REQUIRED not resolved): deterministic bounded jobs check"
    return
  fi
  local tmp good bad_a bad_b out_clean_1 out_clean_2 out_fail_1 out_fail_2 out_fail_2b
  local telemetry telemetry_out cleanup_tmp cleanup_out rc_clean_1 rc_clean_2 rc_fail_1 rc_fail_2 rc_fail_2b rc_bad_jobs
  tmp=$(fm_test_tmproot fm-lint-jobs)
  mkdir -p "$tmp"
  good="$tmp/good.sh"
  bad_a="$tmp/bad-a.sh"
  bad_b="$tmp/bad-b.sh"
  telemetry="$tmp/telemetry.tsv"
  cat > "$good" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${1:-ok}"
SH
  cat > "$bad_a" <<'SH'
#!/usr/bin/env bash
bad_a() {
  local a= b=
  printf '%s\n' "$a$b"
}
SH
  cat > "$bad_b" <<'SH'
#!/usr/bin/env bash
bad_b() {
  printf '%s\n' $1
}
SH

  rc_clean_1=0
  out_clean_1=$(FM_LINT_JOBS=1 "$LINT" "$good" 2>&1) || rc_clean_1=$?
  rc_clean_2=0
  out_clean_2=$(FM_LINT_JOBS=2 "$LINT" "$good" 2>&1) || rc_clean_2=$?
  [ "$rc_clean_1" -eq 0 ] && [ "$rc_clean_2" -eq 0 ] || fail "clean jobs=1/jobs=2 paths must both pass"
  [ "$out_clean_1" = "$out_clean_2" ] || fail "clean jobs=1/jobs=2 output differs"

  rc_fail_1=0
  out_fail_1=$(FM_LINT_JOBS=1 "$LINT" "$bad_a" "$bad_b" 2>&1) || rc_fail_1=$?
  rc_fail_2=0
  out_fail_2=$(FM_LINT_JOBS=2 "$LINT" "$bad_a" "$bad_b" 2>&1) || rc_fail_2=$?
  rc_fail_2b=0
  out_fail_2b=$(FM_LINT_JOBS=2 "$LINT" "$bad_a" "$bad_b" 2>&1) || rc_fail_2b=$?
  [ "$rc_fail_1" -ne 0 ] && [ "$rc_fail_1" -eq "$rc_fail_2" ] && [ "$rc_fail_2" -eq "$rc_fail_2b" ] \
    || fail "failing jobs=1/jobs=2 exit results differ: $rc_fail_1/$rc_fail_2/$rc_fail_2b"
  [ "$out_fail_1" = "$out_fail_2" ] && [ "$out_fail_2" = "$out_fail_2b" ] \
    || fail "failing diagnostics are not byte-identical and deterministic across jobs"
  assert_contains "$out_fail_1" "SC1007" "the first failing root diagnostic was lost"
  assert_contains "$out_fail_1" "SC2086" "the later failing root diagnostic was lost"
  rc_bad_jobs=0
  FM_LINT_JOBS=3 "$LINT" "$good" >/dev/null 2>&1 || rc_bad_jobs=$?
  [ "$rc_bad_jobs" -eq 2 ] || fail "the lint owner must reject unbounded worker counts"

  telemetry_out=$(FM_LINT_JOBS=2 FM_LINT_TELEMETRY="$telemetry" "$LINT" "$good" 2>&1) \
    || fail "telemetry-enabled clean lint failed"
  [ "$telemetry_out" = "$out_clean_2" ] || fail "quiet telemetry changed routine lint output"
  assert_grep $'format\tfm-lint-telemetry-v1' "$telemetry" "telemetry format marker is missing"
  assert_grep $'analysis_mode\tfull' "$telemetry" "telemetry did not record full analysis mode"
  assert_grep $'jobs\t2' "$telemetry" "telemetry did not record bounded jobs"
  assert_grep $'root_count\t1' "$telemetry" "telemetry did not record root count"
  assert_grep $'wall_seconds\t' "$telemetry" "telemetry did not record wall time"
  assert_grep $'user_seconds\t' "$telemetry" "telemetry did not record user CPU"
  assert_grep $'system_seconds\t' "$telemetry" "telemetry did not record system CPU"
  assert_grep $'max_worker_rss_kib\t' "$telemetry" "telemetry did not record maximum RSS"
  assert_grep $'source_boundary_directives\t' "$telemetry" "telemetry did not record source-graph boundaries"
  assert_grep $'shellcheck_processes_start\t' "$telemetry" "telemetry did not record competing ShellCheck conditions"

  cleanup_tmp="$tmp/lint-tmp"
  mkdir -p "$cleanup_tmp"
  cleanup_out=$(TMPDIR="$cleanup_tmp" FM_LINT_JOBS=2 "$LINT" "$good" 2>&1) \
    || fail "cleanup fixture lint failed"
  [ "$cleanup_out" = "$out_clean_2" ] || fail "cleanup fixture changed routine diagnostics"
  [ -z "$(find "$cleanup_tmp" -mindepth 1 -maxdepth 1 -name 'fm-lint.*' -print -quit)" ] \
    || fail "bounded lint left temporary worker state behind"
  pass "jobs=1 and jobs=2 preserve deterministic diagnostics, failures, cleanup bounds, and quiet telemetry"
}

test_worker_trees_stop_on_signal() {
  local tmp fakebin fixture jobs telemetry lint_tmp pid_file out_file telemetry_file
  local parent_pid shellcheck_pid i parent_rc survivor
  tmp=$(fm_test_tmproot fm-lint-signal)
  mkdir -p "$tmp"
  fakebin=$(fm_fakebin "$tmp")
  fixture="$tmp/good.sh"
  cat > "$fixture" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${1:-ok}"
SH
  cat > "$fakebin/shellcheck" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
  printf 'ShellCheck - shell script analysis tool\nversion: 0.11.0\n'
  exit 0
fi
case " $* " in *" --include="*) exit 0 ;; esac
printf '%s\n' "$$" > "$FM_TEST_SHELLCHECK_PID"
trap 'exit 143' HUP INT TERM
while :; do
  sleep 1
done
SH
  chmod +x "$fakebin/shellcheck"

  for jobs in 1 2; do
    for telemetry in off on; do
      lint_tmp="$tmp/lint-$jobs-$telemetry"
      pid_file="$tmp/shellcheck-$jobs-$telemetry.pid"
      out_file="$tmp/output-$jobs-$telemetry"
      telemetry_file=
      mkdir -p "$lint_tmp"
      if [ "$telemetry" = on ]; then
        telemetry_file="$tmp/telemetry-$jobs.tsv"
      fi
      PATH="$fakebin:$PATH" TMPDIR="$lint_tmp" FM_LINT_JOBS="$jobs" \
        FM_LINT_TELEMETRY="$telemetry_file" FM_TEST_SHELLCHECK_PID="$pid_file" \
        "$LINT" "$fixture" > "$out_file" 2>&1 &
      parent_pid=$!
      i=0
      while [ "$i" -lt 500 ] && [ ! -s "$pid_file" ]; do
        kill -0 "$parent_pid" 2>/dev/null || break
        sleep 0.01
        i=$((i + 1))
      done
      [ -s "$pid_file" ] || {
        kill -TERM "$parent_pid" 2>/dev/null || true
        wait "$parent_pid" 2>/dev/null || true
        fail "jobs=$jobs telemetry=$telemetry did not start ShellCheck"
      }
      shellcheck_pid=$(cat "$pid_file")
      kill -TERM "$parent_pid" 2>/dev/null \
        || fail "jobs=$jobs telemetry=$telemetry parent could not be interrupted"
      parent_rc=0
      wait "$parent_pid" 2>/dev/null || parent_rc=$?
      survivor=0
      i=0
      while [ "$i" -lt 100 ] && kill -0 "$shellcheck_pid" 2>/dev/null; do
        sleep 0.01
        i=$((i + 1))
      done
      if kill -0 "$shellcheck_pid" 2>/dev/null; then
        survivor=1
        kill -KILL "$shellcheck_pid" 2>/dev/null || true
      fi
      [ "$parent_rc" -eq 143 ] \
        || fail "jobs=$jobs telemetry=$telemetry signal exit was $parent_rc, expected 143"
      [ "$survivor" -eq 0 ] \
        || fail "jobs=$jobs telemetry=$telemetry left ShellCheck running"
      [ -z "$(find "$lint_tmp" -mindepth 1 -maxdepth 1 -name 'fm-lint.*' -print -quit)" ] \
        || fail "jobs=$jobs telemetry=$telemetry left temporary worker state"
    done
  done
  pass "jobs=1 and jobs=2 stop complete worker trees with and without telemetry"
}

test_root_deadline_names_the_root_and_reaps_the_tree() {
  if ! fm_lint_bounds_supported; then
    pass "SKIP (host cannot enforce the bounded envelope): root deadline kill check"
    return
  fi
  fm_lint_deadline_case off
  # The same deadline and reap, with each root also inside a real capped scope:
  # the process and its group must survive the scope for the watchdog to kill them.
  if fm_lint_real_cap_supported; then
    fm_lint_deadline_case 4096
  else
    pass "SKIP (no systemd user scope with a memory cap): deadline kill inside a capped scope"
  fi
}

fm_lint_deadline_case() {  # <cap-mib|off>
  local cap=$1
  local tmp fakebin stub_log telemetry roots_log out rc
  local blocker ok sentinel_pid child_pid_file stub_pid_file child_pid stub_pid
  tmp=$(fm_test_tmproot fm-lint-bound-deadline)
  fakebin=$(fm_fakebin "$tmp")
  fm_lint_stub_reactive_shellcheck "$fakebin"
  stub_log="$tmp/stub.log"
  telemetry="$tmp/lint.tsv"
  roots_log="$tmp/lint.roots.tsv"
  child_pid_file="$tmp/child.pid"
  stub_pid_file="$tmp/stub.pid"
  blocker="$tmp/blocker.sh"
  ok="$tmp/ok.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$blocker"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$ok"

  sleep 300 &
  sentinel_pid=$!
  rc=0
  out=$(PATH="$fakebin:$PATH" FM_LINT_JOBS=1 \
    FM_LINT_REQUIRE_BOUNDS=1 FM_LINT_ROOT_CGROUP_MIB="$cap" \
    FM_LINT_ROOT_SECONDS=1 FM_LINT_ROOT_GRACE=1 \
    FM_TEST_STUB_LOG="$stub_log" FM_TEST_CHILD_PID="$child_pid_file" \
    FM_TEST_STUB_PID="$stub_pid_file" FM_TEST_BLOCK_SECS=300 \
    "$LINT" --telemetry "$telemetry" "$ok" "$blocker" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a root pinned at the wall deadline unexpectedly passed"
  assert_contains "$out" "blocker.sh" "the timed-out root was not named"
  assert_contains "$out" "reason=timeout" "the timed-out root was not reported as a timeout"
  kill -0 "$sentinel_pid" 2>/dev/null \
    || fail "the lint deadline killed an unrelated sentinel process"
  kill -KILL "$sentinel_pid" 2>/dev/null || true
  wait "$sentinel_pid" 2>/dev/null || true
  if [ -s "$child_pid_file" ]; then
    child_pid=$(cat "$child_pid_file")
    kill -0 "$child_pid" 2>/dev/null \
      && fail "the blocked root's child survived the deadline kill"
  else
    fail "the blocked root never recorded its child pid"
  fi
  if [ -s "$stub_pid_file" ]; then
    stub_pid=$(cat "$stub_pid_file")
    kill -0 "$stub_pid" 2>/dev/null \
      && fail "the blocked root's ShellCheck process survived the deadline kill"
  else
    fail "the blocked root never recorded its ShellCheck pid"
  fi
  [ -f "$roots_log" ] || fail "the run kept no retained per-root sidecar"
  awk -F '\t' '$1 == "end" && $3 ~ /ok\.sh$/ && $10 == "ok" { found=1 } END { exit !found }' \
    "$roots_log" || fail "the sidecar lost the completed root's ok record"
  awk -F '\t' '$1 == "end" && $3 ~ /blocker\.sh$/ && $10 == "timeout" { found=1 } END { exit !found }' \
    "$roots_log" || fail "the sidecar did not record the timed-out root by name"
  pass "a root pinned at the wall deadline fails by name, reaps its tree, and leaves the sentinel alive (cap $cap)"
}

# fm_lint_real_cap_supported: true when a real systemd user scope applies a
# MemoryMax on this host, checked the way bin/fm-lint.sh probes it.
fm_lint_real_cap_supported() {
  command -v systemd-run >/dev/null 2>&1 || return 1
  local got
  # shellcheck disable=SC2016 # The probe text is shell source for bash -c.
  got=$(timeout 10 systemd-run --user --scope -q --collect --expand-environment=no \
    -p MemoryMax=64M -p MemorySwapMax=0 -p OOMPolicy=continue -- \
    bash -c 'cat "/sys/fs/cgroup$(sed -n "s/^0:://p" /proc/self/cgroup)/memory.max"' 2>/dev/null) \
    || return 1
  [ "$got" = 67108864 ]
}

# fm_lint_stub_systemd_run <fakebin-dir>: a systemd-run stand-in for the cap
# tests. It logs each call's arguments on FM_TEST_SD_LOG, answers the cap probe
# (a bash -c that reads memory.max) with the MemoryMax it was given, and runs
# any other wrapped command directly. FM_TEST_SD_MODE=unavailable fails every
# call; undelegated answers the probe with "max", as a host that does not
# delegate the memory controller does.
fm_lint_stub_systemd_run() {
  local fakebin=$1
  cat > "$fakebin/systemd-run" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_TEST_SD_LOG:-/dev/null}"
[ "${FM_TEST_SD_MODE:-ok}" != unavailable ] || { echo 'Failed to connect to bus' >&2; exit 1; }
max=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -p) case "$2" in MemoryMax=*) max=${2#MemoryMax=}; max=${max%M} ;; esac; shift 2 ;;
    --) shift; break ;;
    *) shift ;;
  esac
done
case "$*" in
  "bash -c "*memory.max*)
    if [ "${FM_TEST_SD_MODE:-ok}" = undelegated ]; then echo max; else echo $((max * 1048576)); fi
    exit 0
    ;;
esac
exec "$@"
SH
  chmod +x "$fakebin/systemd-run"
}

test_memory_cap_wraps_each_root_in_a_capped_scope() {
  local tmp fakebin sd_log out rc require_bounds cap
  local -a modes=(0)
  fm_lint_bounds_supported && modes=(0 1)
  tmp=$(fm_test_tmproot fm-lint-cap-scope)
  fakebin=$(fm_fakebin "$tmp")
  fm_lint_stub_reactive_shellcheck "$fakebin"
  fm_lint_stub_systemd_run "$fakebin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/a.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/b.sh"
  for require_bounds in "${modes[@]}"; do
    for cap in 8192 300; do
      sd_log="$tmp/sd.$require_bounds.$cap.log"
      rc=0
      out=$(PATH="$fakebin:$PATH" FM_LINT_JOBS=1 FM_LINT_REQUIRE_BOUNDS="$require_bounds" \
        FM_TEST_SD_LOG="$sd_log" \
        FM_LINT_ROOT_CGROUP_MIB="$cap" \
        "$LINT" --telemetry "$tmp/t.$require_bounds.$cap.tsv" "$tmp/a.sh" "$tmp/b.sh" 2>&1) || rc=$?
      [ "$rc" -eq 0 ] || fail "a clean run failed under the cap (bounds=$require_bounds cap=$cap)"$'\n'"$out"
      assert_contains "$out" "per-root memory cap $cap MiB" "the run did not say the cap was active"
      [ "$(grep -c 'no per-root memory cap' <<<"$out")" -eq 0 ] || fail "an active cap also reported it was unavailable"
      # One probe, then one scope for each ShellCheck process (the root and its ratchet check).
      [ "$(grep -c 'memory.max' "$sd_log")" -eq 1 ] || fail "the cap was not probed exactly once"
      [ "$(grep -vc 'memory.max' "$sd_log")" -eq 4 ] \
        || fail "each root's two ShellCheck processes did not each get a scope (bounds=$require_bounds)"$'\n'"$(cat "$sd_log")"
      [ "$(grep -c -- "-p MemoryMax=${cap}M -p MemorySwapMax=0 -p OOMPolicy=continue" "$sd_log")" -eq 5 ] \
        || fail "a scope lacked the MemoryMax, no-swap or OOMPolicy=continue property"$'\n'"$(cat "$sd_log")"
      grep -q "^meta"$'\t'"root_memory_cap_mib"$'\t'"$cap\$" "$tmp/t.$require_bounds.$cap.roots.tsv" \
        || fail "the roots sidecar did not record the active cap"
    done
  done
  pass "every ShellCheck process runs in its own capped scope, probed once, with the setting honored"
}

test_memory_cap_unavailable_says_so_once_and_still_lints() {
  local tmp fakebin out rc mode stub_log
  tmp=$(fm_test_tmproot fm-lint-cap-unavailable)
  fakebin=$(fm_fakebin "$tmp")
  fm_lint_stub_reactive_shellcheck "$fakebin"
  fm_lint_stub_systemd_run "$fakebin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/a.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/b.sh"
  for mode in unavailable undelegated; do
    stub_log="$tmp/stub.$mode.log"
    rc=0
    out=$(PATH="$fakebin:$PATH" FM_LINT_JOBS=1 FM_LINT_ROOT_CGROUP_MIB='' \
      FM_TEST_SD_MODE="$mode" FM_TEST_STUB_LOG="$stub_log" \
      "$LINT" --telemetry "$tmp/t.$mode.tsv" "$tmp/a.sh" "$tmp/b.sh" 2>&1) || rc=$?
    [ "$rc" -eq 0 ] || fail "a host without the cap failed instead of linting as before ($mode)"$'\n'"$out"
    [ "$(grep -c 'no per-root memory cap' <<<"$out")" -eq 1 ] \
      || fail "the missing cap was not reported in exactly one line ($mode)"$'\n'"$out"
    grep -q 'a.sh' "$stub_log" || fail "a.sh was not linted without the cap ($mode)"
    grep -q 'b.sh' "$stub_log" || fail "b.sh was not linted without the cap ($mode)"
    grep -q "^meta"$'\t'"root_memory_cap_mib"$'\t'"none\$" "$tmp/t.$mode.roots.tsv" \
      || fail "the sidecar claimed a cap that was not applied ($mode)"
  done
  for mode in abc 0; do
    rc=0
    out=$(PATH="$fakebin:$PATH" FM_LINT_ROOT_CGROUP_MIB="$mode" "$LINT" "$tmp/a.sh" 2>&1) || rc=$?
    [ "$rc" -eq 2 ] || fail "FM_LINT_ROOT_CGROUP_MIB=$mode was not refused"
    assert_contains "$out" "FM_LINT_ROOT_CGROUP_MIB must be a positive integer or off" "the bad setting was not named"
  done
  pass "a host that cannot apply the cap says so in one line and lints as before; a bad setting is refused"
}

test_memory_cap_kill_is_a_named_memory_limit_not_a_finding() {
  local tmp fakebin out rc
  tmp=$(fm_test_tmproot fm-lint-cap-kill)
  fakebin=$(fm_fakebin "$tmp")
  fm_lint_stub_reactive_shellcheck "$fakebin"
  fm_lint_stub_systemd_run "$fakebin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/ok.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/cap-kill.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/cap-kill-sources.sh"

  # A root the cap kills, with and without sources, fails by name as a memory limit.
  rc=0
  out=$(PATH="$fakebin:$PATH" FM_LINT_JOBS=1 FM_LINT_ROOT_CGROUP_MIB='' \
    "$LINT" --telemetry "$tmp/dead.tsv" "$tmp/ok.sh" "$tmp/cap-kill.sh" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a root killed by the cap passed silently"
  assert_contains "$out" "cap-kill.sh exceeded the per-root memory limit (cgroup cap 8192 MiB)" \
    "the killed root was not named as a memory limit"
  assert_contains "$out" "reason=memory" "the cap kill was not classified as memory"
  assert_not_contains "$out" "signal:KILL" "the cap kill was reported as a bare signal"
  awk -F '\t' '$1 == "end" && $3 ~ /cap-kill\.sh$/ && $10 == "memory" { found=1 } END { exit !found }' \
    "$tmp/dead.roots.tsv" || fail "the sidecar did not record the cap-killed root as memory"

  # A root only the source-following pass kills takes the documented retry, as in CI.
  rc=0
  out=$(PATH="$fakebin:$PATH" FM_LINT_JOBS=1 FM_LINT_ROOT_CGROUP_MIB='' \
    "$LINT" --telemetry "$tmp/retry.tsv" "$tmp/cap-kill-sources.sh" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "a root that fits without sources did not take the memory retry"$'\n'"$out"
  assert_contains "$out" "cap-kill-sources.sh hit the memory ceiling with --external-sources" \
    "the retry did not name the root"
  awk -F '\t' '$1 == "end" && $3 ~ /cap-kill-sources\.sh$/ && $10 == "memory-fallback" { found=1 } END { exit !found }' \
    "$tmp/retry.roots.tsv" || fail "the sidecar did not record the memory fallback"

  # With the cap off nothing changes: a bare kill stays a signal, never a memory limit.
  rc=0
  out=$(PATH="$fakebin:$PATH" FM_LINT_JOBS=1 FM_LINT_ROOT_CGROUP_MIB=off \
    "$LINT" "$tmp/cap-kill.sh" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a killed root passed with the cap off"
  assert_contains "$out" "reason=signal:KILL" "the cap-off classification changed"
  assert_not_contains "$out" "memory limit" "the cap-off run claimed a memory limit"
  pass "a cap kill fails by name as a memory limit, retries without sources, and cap off keeps the old reasons"
}

test_memory_cap_real_scope_kills_only_the_hoarder() {
  if ! fm_lint_real_cap_supported; then
    pass "SKIP (no systemd user scope with a memory cap): real cap check"
    return
  fi
  local tmp fakebin out rc require_bounds sentinel_pid
  local -a modes=(0)
  fm_lint_bounds_supported && modes=(0 1)
  tmp=$(fm_test_tmproot fm-lint-cap-real)
  fakebin=$(fm_fakebin "$tmp")
  fm_lint_stub_reactive_shellcheck "$fakebin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/ok.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/hoarder.sh"
  for require_bounds in "${modes[@]}"; do
    # The hoarder allocates 512 MiB; a real 256 MiB scope kills it, and only it.
    sleep 300 &
    sentinel_pid=$!
    rc=0
    out=$(PATH="$fakebin:$PATH" FM_LINT_JOBS=1 FM_LINT_REQUIRE_BOUNDS="$require_bounds" \
      FM_LINT_ROOT_CGROUP_MIB=256 \
      "$LINT" --telemetry "$tmp/t.$require_bounds.tsv" "$tmp/ok.sh" "$tmp/hoarder.sh" 2>&1) || rc=$?
    [ "$rc" -ne 0 ] || fail "a root over its real cap passed (bounds=$require_bounds)"
    assert_contains "$out" "hoarder.sh exceeded the per-root memory limit (cgroup cap 256 MiB)" \
      "the real cap kill was not named as a memory limit"
    kill -0 "$sentinel_pid" 2>/dev/null || fail "the cap kill took an unrelated sentinel process with it"
    kill -KILL "$sentinel_pid" 2>/dev/null || true
    wait "$sentinel_pid" 2>/dev/null || true
    awk -F '\t' '$1 == "end" && $3 ~ /ok\.sh$/ && $10 == "ok" { found=1 } END { exit !found }' \
      "$tmp/t.$require_bounds.roots.tsv" || fail "the clean root did not pass beside the capped one"
  done
  pass "a real capped scope kills only the root over its cap, which fails by name as a memory limit"
}

test_root_memory_limit_reports_a_named_death() {
  if ! fm_lint_bounds_supported; then
    pass "SKIP (host cannot enforce the bounded envelope): memory-limit death check"
    return
  fi
  local tmp fakebin stub_log telemetry roots_log out rc hoarder ok
  local sentinel_pid
  tmp=$(fm_test_tmproot fm-lint-bound-memory)
  fakebin=$(fm_fakebin "$tmp")
  fm_lint_stub_reactive_shellcheck "$fakebin"
  stub_log="$tmp/stub.log"
  telemetry="$tmp/lint.tsv"
  roots_log="$tmp/lint.roots.tsv"
  hoarder="$tmp/hoarder.sh"
  ok="$tmp/ok.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$hoarder"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$ok"

  # Control: with no memory limit the same allocator succeeds, so a memory
  # death below can only come from the enforced cap.
  rc=0
  out=$(PATH="$fakebin:$PATH" FM_LINT_JOBS=1 \
    FM_TEST_STUB_LOG="$stub_log" \
    "$LINT" --telemetry "$tmp/control.tsv" "$ok" "$hoarder" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "the allocator failed without any memory limit"$'\n'"$out"
  grep -q $'^meta\tbounds_enforced\t0$' "$tmp/control.roots.tsv" \
    || fail "the control run was not unbounded"
  awk -F '\t' '$1 == "end" && $3 ~ /hoarder\.sh$/ && $10 == "ok" { found=1 } END { exit !found }' \
    "$tmp/control.roots.tsv" || fail "the uncapped allocator root did not complete ok"

  # The hoarder stub allocates 512 MiB; under a 256 MiB address-space limit
  # the allocator is refused and the run must name the root, not survive.
  sleep 300 &
  sentinel_pid=$!
  rc=0
  out=$(PATH="$fakebin:$PATH" FM_LINT_JOBS=1 \
    FM_LINT_REQUIRE_BOUNDS=1 FM_LINT_ROOT_MEMORY_KIB=262144 \
    FM_TEST_STUB_LOG="$stub_log" \
    "$LINT" --telemetry "$telemetry" "$ok" "$hoarder" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a root killed by its memory limit unexpectedly passed"
  assert_contains "$out" "hoarder.sh" "the memory-limited root was not named"
  assert_contains "$out" "reason=memory" "the memory-limit death was not classified as memory"
  kill -0 "$sentinel_pid" 2>/dev/null \
    || fail "the memory-limit kill took an unrelated sentinel process with it"
  kill -KILL "$sentinel_pid" 2>/dev/null || true
  wait "$sentinel_pid" 2>/dev/null || true
  awk -F '\t' '$1 == "end" && $3 ~ /hoarder\.sh$/ && $10 == "memory" { found=1 } END { exit !found }' \
    "$roots_log" || fail "the sidecar did not record the memory-limited root by name"
  awk -F '\t' '$1 == "end" && $3 ~ /ok\.sh$/ && $10 == "ok" { found=1 } END { exit !found }' \
    "$roots_log" || fail "the sidecar lost the clean root's record"
  pass "a root refused by its enforced memory limit fails by name with a memory reason"
}

test_memory_failure_retries_without_external_sources() {
  local tmp fakebin fixture out rc log rss_kib require_bounds=0 mode
  local -a modes=(0)
  if fm_lint_bounds_supported; then
    require_bounds=1
    modes=(1 0)
  fi
  tmp=$(fm_test_tmproot fm-lint-memory-fallback)
  fakebin=$(fm_fakebin "$tmp")
  fixture="$tmp/teardown.sh"
  log="$tmp/flags.log"
  printf '#!/usr/bin/env bash\n# shellcheck source=lib.sh\nexit 0\n' > "$fixture"
  cat > "$fakebin/shellcheck" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf 'ShellCheck - shell script analysis tool\nversion: 0.11.0\n'
  exit 0
fi
case " $* " in *" --include="*) exit 0 ;; esac
follow=no
exclude=none
while [ "$#" -gt 0 ] && [ "$1" != -- ]; do
  case "$1" in
    --external-sources) follow=yes ;;
    --exclude=*) exclude=${1#--exclude=} ;;
  esac
  shift
done
shift
printf '%s\t%s\n' "$follow" "$exclude" >> "$FM_TEST_FALLBACK_LOG"
if [ "$follow" = yes ]; then
  printf 'shellcheck: Heap exhausted;\n' >&2
  exit 251
fi
exit 0
SH
  chmod +x "$fakebin/shellcheck"

  for mode in "${modes[@]}"; do
    : > "$log"
    rc=0
    out=$(PATH="$fakebin:$PATH" FM_LINT_JOBS=1 FM_LINT_REQUIRE_BOUNDS="$mode" \
      FM_TEST_FALLBACK_LOG="$log" "$LINT" --telemetry "$tmp/pass.$mode.tsv" "$fixture" 2>&1) || rc=$?
    [ "$rc" -eq 0 ] || fail "a clean no-source fallback did not pass (bounded=$mode)"$'\n'"$out"
    assert_grep $'source_directives\t1' "$tmp/pass.$mode.tsv" "telemetry lost the root's source directive"
    assert_grep $'source_followed_directives\t0' "$tmp/pass.$mode.tsv" \
      "telemetry counted a source directive that the passing fallback did not follow"
    [ "$(cat "$log")" = "$(printf 'yes\tnone\nno\tSC1091,SC2034,SC2153,SC2329')" ] \
      || fail "the memory failure did not retry without external sources and exclude only cross-file codes"$'\n'"$(cat "$log")"
    assert_contains "$out" "hit the memory ceiling with --external-sources (reason=memory rc=251)" \
      "the fallback was not identified in the output"
    assert_contains "$out" "fallback passed with cross-file codes excluded (SC1091,SC2034,SC2153,SC2329)" \
      "the narrower fallback result was not disclosed"
    awk -F '\t' '$1 == "end" && $3 ~ /teardown\.sh$/ && $9 == 0 && $10 == "memory-fallback" { found=1 } END { exit !found }' \
      "$tmp/pass.$mode.roots.tsv" || fail "the clean fallback was not recorded distinctly"
    rss_kib=$(awk -F '\t' '$1 == "end" && $3 ~ /teardown\.sh$/ { print $11 }' "$tmp/pass.$mode.roots.tsv")
    if [ "$mode" -eq 1 ]; then
      assert_grep $'meta\tbounds_enforced\t1' "$tmp/pass.$mode.roots.tsv" \
        "the bounded fallback did not enforce bounds"
      case "$rss_kib" in ''|*[!0-9]*) fail "the fallback attempts lost per-root RSS reporting: $rss_kib" ;; esac
    else
      assert_grep $'meta\tbounds_enforced\t0' "$tmp/pass.$mode.roots.tsv" \
        "the unbounded fallback unexpectedly enforced bounds"
      [ "$rss_kib" = unavailable ] || fail "the unbounded fallback unexpectedly reported RSS: $rss_kib"
    fi
  done

  if ! pinned_ready; then
    pass "SKIP (ShellCheck $REQUIRED not resolved): real fallback finding check"
    return
  fi
  local real_shellcheck
  real_shellcheck=$(command -v shellcheck)
  cat > "$fakebin/shellcheck" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  exec "$FM_REAL_SHELLCHECK" "$@"
fi
case " $* " in *" --include="*) exit 0 ;; esac
for arg in "$@"; do
  if [ "$arg" = --external-sources ]; then
    printf 'shellcheck: Heap exhausted;\n' >&2
    exit 251
  fi
done
exec "$FM_REAL_SHELLCHECK" "$@"
SH
  chmod +x "$fakebin/shellcheck"
  # shellcheck disable=SC2016 # The fixture intentionally contains an unexpanded parameter.
  printf '#!/usr/bin/env bash\nx=$1\nprintf "%%s\\n" $x\n' > "$fixture"
  rc=0
  out=$(PATH="$fakebin:$PATH" FM_REAL_SHELLCHECK="$real_shellcheck" \
    FM_LINT_JOBS=1 FM_LINT_REQUIRE_BOUNDS="$require_bounds" \
    "$LINT" --telemetry "$tmp/finding.tsv" "$fixture" 2>&1) || rc=$?
  [ "$rc" -eq 1 ] || fail "a real ShellCheck finding in the fallback did not fail lint (exit $rc)"$'\n'"$out"
  assert_contains "$out" "fallback reason=findings rc=1" \
    "the fallback finding was not identified"
  assert_contains "$out" "SC2086" "the real fallback finding was not reported"
  awk -F '\t' '$1 == "end" && $3 ~ /teardown\.sh$/ && $9 == 1 && $10 == "findings" { found=1 } END { exit !found }' \
    "$tmp/finding.roots.tsv" || fail "the fallback finding was not recorded as a failure"
  pass "memory failures retry without source following, exclude cross-file codes, and preserve a real fallback finding"
}

test_memory_fallback_spends_only_the_remaining_root_deadline() {
  if ! fm_lint_bounds_supported; then
    pass "SKIP (host cannot enforce the bounded envelope): fallback deadline check"
    return
  fi
  local tmp fakebin fixture log out rc duration_ms
  tmp=$(fm_test_tmproot fm-lint-fallback-deadline)
  fakebin=$(fm_fakebin "$tmp")
  fixture="$tmp/teardown.sh"
  log="$tmp/attempts.log"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fixture"
  cat > "$fakebin/shellcheck" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf 'ShellCheck - shell script analysis tool\nversion: 0.11.0\n'
  exit 0
fi
case " $* " in *" --include="*) exit 0 ;; esac
for arg in "$@"; do
  if [ "$arg" = --external-sources ]; then
    printf 'follow\n' >> "$FM_TEST_ATTEMPT_LOG"
    sleep "$FM_TEST_FIRST_SECS"
    printf 'shellcheck: Heap exhausted;\n' >&2
    exit 251
  fi
done
printf 'fallback\n' >> "$FM_TEST_ATTEMPT_LOG"
sleep 60
exit 0
SH
  chmod +x "$fakebin/shellcheck"

  # A 3s first attempt leaves about 3s of the 6s deadline, so the retry is
  # killed there; a fresh deadline would let the root run for about 9s.
  : > "$log"
  rc=0
  out=$(PATH="$fakebin:$PATH" FM_LINT_JOBS=1 FM_LINT_REQUIRE_BOUNDS=1 \
    FM_LINT_ROOT_SECONDS=6 FM_LINT_ROOT_GRACE=1 \
    FM_TEST_ATTEMPT_LOG="$log" FM_TEST_FIRST_SECS=3 \
    "$LINT" --telemetry "$tmp/partial.tsv" "$fixture" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a fallback cut off by the root deadline unexpectedly passed"
  [ "$(cat "$log")" = "$(printf 'follow\nfallback')" ] \
    || fail "the root did not retry once with its remaining time"$'\n'"$(cat "$log")"
  assert_contains "$out" "fallback reason=timeout" \
    "the fallback was not stopped by the root's remaining deadline"$'\n'"$out"
  duration_ms=$(awk -F '\t' '$1 == "end" && $3 ~ /teardown\.sh$/ { print $8 }' "$tmp/partial.roots.tsv")
  [ "$duration_ms" -lt 7000 ] \
    || fail "the first attempt and fallback together exceeded the root deadline plus grace: ${duration_ms}ms"

  # With under a second of the deadline left, no retry starts.
  : > "$log"
  rc=0
  out=$(PATH="$fakebin:$PATH" FM_LINT_JOBS=1 FM_LINT_REQUIRE_BOUNDS=1 \
    FM_LINT_ROOT_SECONDS=6 FM_LINT_ROOT_GRACE=1 \
    FM_TEST_ATTEMPT_LOG="$log" FM_TEST_FIRST_SECS=5.2 \
    "$LINT" --telemetry "$tmp/spent.tsv" "$fixture" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a memory failure with no deadline left unexpectedly passed"
  [ "$(cat "$log")" = follow ] \
    || fail "a fallback started with no time left in the root deadline"$'\n'"$(cat "$log")"
  assert_contains "$out" "no time left in its 6s deadline to retry without it" \
    "the skipped fallback was not explained"$'\n'"$out"
  awk -F '\t' '$1 == "end" && $3 ~ /teardown\.sh$/ && $10 == "memory" && $12 == 1 { found=1 } END { exit !found }' \
    "$tmp/spent.roots.tsv" || fail "the unretried memory failure was not recorded as a source-following memory failure"
  pass "a memory fallback runs only within the time left in its root's original deadline"
}

test_memory_evidence_outranks_findings_and_signal_reasons() {
  local tmp fakebin roots_log out rc name reason bounded
  local -a roots modes
  tmp=$(fm_test_tmproot fm-lint-memory-evidence)
  fakebin=$(fm_fakebin "$tmp")
  fm_lint_stub_reactive_shellcheck "$fakebin"
  roots=()
  for name in oom-exit1 oom-heap oom-kill oom-text-findings; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/$name.sh"
    roots+=("$tmp/$name.sh")
  done
  modes=(0)
  if fm_lint_bounds_supported; then
    modes+=(1)
  fi

  # A memory death reports memory whether the runtime exits 1 with a
  # program-prefixed OOM error, exits with GHC's heap-exhaustion status, or is
  # SIGKILLed after printing OOM text; a findings root whose echoed source line
  # merely quotes "out of memory" stays findings.
  for bounded in "${modes[@]}"; do
    roots_log="$tmp/lint.$bounded.roots.tsv"
    rc=0
    if [ "$bounded" = 1 ]; then
      out=$(PATH="$fakebin:$PATH" FM_LINT_JOBS=1 FM_LINT_REQUIRE_BOUNDS=1 \
        "$LINT" --telemetry "$tmp/lint.$bounded.tsv" "${roots[@]}" 2>&1) || rc=$?
    else
      out=$(PATH="$fakebin:$PATH" FM_LINT_JOBS=1 \
        "$LINT" --telemetry "$tmp/lint.$bounded.tsv" "${roots[@]}" 2>&1) || rc=$?
    fi
    [ "$rc" -ne 0 ] || fail "memory deaths unexpectedly passed (bounded=$bounded)"
    for name in oom-exit1 oom-heap oom-kill oom-text-findings; do
      reason=$(awk -F '\t' -v root="/$name.sh" \
        '$1 == "end" && substr($3, length($3) - length(root) + 1) == root { print $10 }' \
        "$roots_log")
      case "$name" in
        oom-text-findings)
          [ "$reason" = findings ] \
            || fail "$name was classified '$reason', expected findings (bounded=$bounded)"$'\n'"$out"
          ;;
        *)
          [ "$reason" = memory ] \
            || fail "$name was classified '$reason', expected memory (bounded=$bounded)"$'\n'"$out"
          ;;
      esac
    done
  done
  pass "explicit memory evidence outranks findings and signal reasons (modes: ${modes[*]})"
}

test_source_excerpt_with_oom_text_stays_findings() {
  if ! pinned_ready; then
    pass "SKIP (ShellCheck $REQUIRED not resolved): OOM-text source excerpt check"
    return
  fi
  local tmp fixture out rc reason
  tmp=$(fm_test_tmproot fm-lint-oom-text-excerpt)
  fixture="$tmp/excerpt.sh"
  # The finding's echoed source excerpt reads like a runtime OOM error; the
  # root still exits with ordinary findings and must be reported as findings.
  cat > "$fixture" <<'SH'
#!/usr/bin/env bash
x=$1
shellcheck: out of memory $x
SH
  rc=0
  out=$("$LINT" --telemetry "$tmp/lint.tsv" "$fixture" 2>&1) || rc=$?
  [ "$rc" -eq 1 ] || fail "a root with an ordinary finding exited $rc, expected 1"$'\n'"$out"
  assert_contains "$out" "shellcheck: out of memory" "the source excerpt was not echoed with the finding"
  assert_contains "$out" "SC2086" "the ordinary finding was not reported"
  reason=$(awk -F '\t' '$1 == "end" && $3 ~ /excerpt\.sh$/ { print $10 }' "$tmp/lint.roots.tsv")
  [ "$reason" = findings ] \
    || fail "a source excerpt quoting OOM text was classified '$reason', expected findings"$'\n'"$out"

  # A root whose path contains OOM words and cannot be opened fails with an
  # ordinary file error that names the path on stderr; it is an error, not a
  # memory death.
  rc=0
  out=$("$LINT" --telemetry "$tmp/missing.tsv" "$tmp/out of memory.sh" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a missing root unexpectedly passed"$'\n'"$out"
  assert_contains "$out" "out of memory.sh" "the missing root's file error did not name its path"
  reason=$(awk -F '\t' '$1 == "end" && $3 ~ /out of memory\.sh$/ { print $10 }' "$tmp/missing.roots.tsv")
  case "$reason" in
    error:*) ;;
    *) fail "a missing root named with OOM words was classified '$reason', expected error"$'\n'"$out" ;;
  esac
  pass "OOM words in a source excerpt or a root path never classify a root as memory"
}

test_require_bounds_refuses_when_enforcement_is_missing() {
  local tmp fakebin stub_log fixture out rc lone_dir
  tmp=$(fm_test_tmproot fm-lint-require-bounds)
  fakebin=$(fm_fakebin "$tmp")
  fm_lint_stub_shellcheck "$fakebin" "$tmp/stub.log"
  stub_log="$tmp/stub.log"
  fixture="$tmp/clean.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fixture"

  # A script copied without its sibling watchdog library cannot enforce the
  # wall deadline, so a required-bounds run must refuse before ShellCheck.
  lone_dir="$tmp/lone"
  mkdir -p "$lone_dir"
  cp "$LINT" "$lone_dir/fm-lint.sh"
  chmod +x "$lone_dir/fm-lint.sh"
  rc=0
  out=$(PATH="$fakebin:$PATH" FM_LINT_REQUIRE_BOUNDS=1 \
    "$lone_dir/fm-lint.sh" "$fixture" 2>&1) || rc=$?
  [ "$rc" -eq 2 ] || fail "a watchdog-less run under REQUIRE_BOUNDS exited $rc, expected 2"
  assert_contains "$out" "fm-timeout-lib.sh" "the refusal did not name the missing watchdog library"
  assert_contains "$out" "refusing to lint uncapped" "the refusal did not explain itself"
  [ ! -s "$stub_log" ] \
    || fail "a watchdog-refused run still invoked ShellCheck"

  if ( ulimit -v 65536 ) 2>/dev/null; then
    # The host accepts the memory limit, so a required-bounds run proceeds and
    # still lints the root.
    rc=0
    out=$(PATH="$fakebin:$PATH" FM_LINT_REQUIRE_BOUNDS=1 \
      "$LINT" "$fixture" 2>&1) || rc=$?
    [ "$rc" -eq 0 ] || fail "an enforceable bounded run was refused"$'\n'"$out"
    [ -s "$stub_log" ] || fail "an enforceable bounded run never invoked ShellCheck"
  else
    # The host rejects the address-space limit outright (macOS), so the run
    # must refuse by name rather than lint uncapped.
    rc=0
    out=$(PATH="$fakebin:$PATH" FM_LINT_REQUIRE_BOUNDS=1 \
      "$LINT" "$fixture" 2>&1) || rc=$?
    [ "$rc" -eq 2 ] || fail "an unenforceable memory limit under REQUIRE_BOUNDS exited $rc, expected 2"
    assert_contains "$out" "FM_LINT_ROOT_MEMORY_KIB" \
      "the refusal did not name the unenforceable memory limit"
    assert_contains "$out" "refusing to lint uncapped" "the refusal did not explain itself"
    [ ! -s "$stub_log" ] \
      || fail "a bound-refused run still invoked ShellCheck"
  fi
  pass "FM_LINT_REQUIRE_BOUNDS refuses missing enforcement and proceeds when enforceable"
}

test_pinned_shellcheck_memory_limit() {
  if ! pinned_ready; then
    pass "SKIP (ShellCheck $REQUIRED not resolved): pinned memory-envelope check"
    return
  fi
  if ! fm_lint_bounds_supported; then
    pass "SKIP (host cannot enforce the bounded envelope): pinned memory-envelope check"
    return
  fi
  local tmp telemetry roots_log out rc fixture
  tmp=$(fm_test_tmproot fm-lint-pinned-memory)
  telemetry="$tmp/lint.tsv"
  roots_log="$tmp/lint.roots.tsv"
  fixture="$tmp/small.sh"
  printf '#!/usr/bin/env bash\nprintf ok\n' > "$fixture"

  # The pinned ShellCheck must start and lint under the configured memory
  # limit - this is what proves the address-space cap leaves GHC enough head
  # room instead of discovering the conflict mid-partition in CI.
  rc=0
  out=$(FM_LINT_REQUIRE_BOUNDS=1 "$LINT" \
    --telemetry "$telemetry" "$fixture" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "pinned ShellCheck did not lint under the default memory limit"$'\n'"$out"
  grep -q $'^meta\tbounds_enforced\t1$' "$roots_log" \
    || fail "the sidecar did not record enforced bounds"
  grep -q $'^meta\troot_memory_limit_kib\t12582912$' "$roots_log" \
    || fail "the sidecar did not record the applied memory limit"
  awk -F '\t' '$1 == "end" && $3 ~ /small\.sh$/ && $10 == "ok" { found=1 } END { exit !found }' \
    "$roots_log" || fail "the pinned root did not complete ok under the memory limit"

  # A limit below the pinned binary's own mapped size must bind the same
  # pinned root: it is refused or killed and named, never silently uncapped.
  # GHC shrinks its heap reservation to fit a larger cap, so a small file can
  # still lint under a few hundred MiB; only a cap under the binary itself
  # binds on every Linux architecture.
  rc=0
  out=$(FM_LINT_REQUIRE_BOUNDS=1 FM_LINT_ROOT_MEMORY_KIB=8192 \
    "$LINT" --telemetry "$tmp/tiny.tsv" "$fixture" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "pinned ShellCheck ignored an 8 MiB address-space limit"
  assert_contains "$out" "small.sh" "the memory-bound pinned root was not named"
  awk -F '\t' '$1 == "end" && $3 ~ /small\.sh$/ && $10 != "ok" && $10 != "findings" { found=1 } END { exit !found }' \
    "$tmp/tiny.roots.tsv" || fail "the over-limit pinned root was not recorded as an abnormal end"$'\n'"$out"
  pass "the pinned ShellCheck both respects and survives under the memory envelope"
}

test_sidecar_result_exit_reflects_final_status() {
  local tmp fakebin log telemetry roots_log out rc
  tmp=$(fm_test_tmproot fm-lint-sidecar-result)
  fakebin=$(fm_fakebin "$tmp")
  log="$tmp/shellcheck.log"
  telemetry="$tmp/lint.tsv"
  roots_log="$tmp/lint.roots.tsv"
  mkdir -p "$tmp/repo/bin/backends" "$tmp/repo/tests" "$tmp/repo/.github/workflows"
  cp "$LINT" "$tmp/repo/bin/fm-lint.sh"
  cp "$ROOT/bin/fm-timeout-lib.sh" "$tmp/repo/bin/fm-timeout-lib.sh"
  cat > "$tmp/repo/bin/fm-lint-workflows.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$tmp/repo/bin/backends/noop.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$tmp/repo/tests/noop.test.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  printf '#!/usr/bin/env bash\nbd close fm-example\n' > "$tmp/repo/bin/direct-beads.sh"
  chmod +x "$tmp/repo/bin/fm-lint.sh" "$tmp/repo/bin/fm-lint-workflows.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/repo/bin/fm-instruction-size-check.sh" && chmod +x "$tmp/repo/bin/fm-instruction-size-check.sh"
  fm_lint_stub_shellcheck "$fakebin" "$log"

  # Every ShellCheck root passes, then the backend-purity check fails the run:
  # the retained records must carry that final status, not the clean lint exit.
  rc=0
  out=$(cd "$tmp/repo" && CI=true PATH="$fakebin:$PATH" \
    "$tmp/repo/bin/fm-lint.sh" --telemetry "$telemetry" 2>&1) || rc=$?
  [ "$rc" -eq 1 ] || fail "a backend-purity failure did not fail the lint run (exit $rc)"$'\n'"$out"
  assert_contains "$out" "direct Beads CLI invocation bypasses tasks-axi" \
    "the run did not report its backend-purity failure"
  grep -q $'^meta\tresult_exit\t1$' "$roots_log" \
    || fail "the sidecar recorded the pre-check status instead of the final exit"
  grep -q $'^result_exit\t1$' "$telemetry" \
    || fail "telemetry recorded the pre-check status instead of the final exit"
  pass "the roots sidecar and telemetry record the run's final exit status"
}

test_roots_sidecar_records_per_root_lifecycle() {
  local tmp fakebin stub_log telemetry roots_log out rc
  local alpha beta gamma
  tmp=$(fm_test_tmproot fm-lint-roots-log)
  fakebin=$(fm_fakebin "$tmp")
  fm_lint_stub_shellcheck "$fakebin" "$tmp/stub.log"
  stub_log="$tmp/stub.log"
  telemetry="$tmp/lint.tsv"
  roots_log="$tmp/lint.roots.tsv"
  alpha="$tmp/alpha.sh"; beta="$tmp/beta.sh"; gamma="$tmp/gamma.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$alpha"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$beta"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$gamma"

  rc=0
  out=$(PATH="$fakebin:$PATH" FM_TEST_STUB_LOG="$stub_log" \
    "$LINT" --telemetry "$telemetry" "$alpha" "$beta" "$gamma" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "a clean bounded run failed"$'\n'"$out"
  [ -f "$roots_log" ] || fail "the run wrote no per-root sidecar beside telemetry"
  grep -q $'^format\tfm-lint-roots-v1$' "$roots_log" \
    || fail "the sidecar is missing its format header"
  grep -q $'^meta\tbounds_enforced\t0$' "$roots_log" \
    || fail "the sidecar did not record the unenforced bounds state"
  grep -q $'^meta\ttiming_mechanism\tnone$' "$roots_log" \
    || fail "the sidecar did not record the timing mechanism"
  grep -q $'^meta\troot_deadline_seconds\tunbounded$' "$roots_log" \
    || fail "the sidecar did not record the unbounded deadline state"
  grep -q $'^meta\troot_memory_limit_kib\tunbounded$' "$roots_log" \
    || fail "the sidecar did not record the unbounded memory state"
  grep -q $'^meta\troots_completed\t3$' "$roots_log" \
    || fail "the sidecar did not count three completed roots"
  [ "$(grep -c '^begin' "$roots_log")" -eq 3 ] \
    || fail "the sidecar did not log a begin record per root"
  [ "$(awk -F '\t' '$1 == "end" && $10 == "ok" { n++ } END { print n + 0 }' "$roots_log")" -eq 3 ] \
    || fail "the sidecar did not log an ok end record per root"
  [ "$(awk -F '\t' '$1 == "end" && ($8 == "" || $8 !~ /^[0-9]+$/) { n++ } END { print n + 0 }' "$roots_log")" -eq 0 ] \
    || fail "an end record is missing its exit status"
  pass "the retained sidecar records each root's lifecycle with a mode, reason, and duration"
}

# fm_lint_cache_repo <dir>: a minimal repository root that carries its own copy
# of the lint owner, so a test can steer which files exist, what they source,
# and which ratchet exceptions apply without touching the real tree. The
# workflow-lint step is a stub because the fixture carries no workflows.
fm_lint_cache_repo() {
  mkdir -p "$1/bin/backends" "$1/tests" "$1/lib"
  cp "$LINT" "$1/bin/fm-lint.sh"
  cp "$ROOT/bin/fm-timeout-lib.sh" "$1/bin/fm-timeout-lib.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$1/bin/fm-lint-workflows.sh"
  chmod +x "$1/bin/fm-lint-workflows.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$1/bin/fm-instruction-size-check.sh" && chmod +x "$1/bin/fm-instruction-size-check.sh"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$1/bin/backends/b.sh"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$1/tests/t.sh"
}

# fm_lint_cache_counts <output>: "<hits> <misses> <uncacheable>" from the
# result-cache summary line, or "none" when the run printed no such line.
fm_lint_cache_counts() {
  printf '%s\n' "$1" | sed -n 's/^fm-lint.sh: result cache: \([0-9]*\) hits, \([0-9]*\) misses, \([0-9]*\) uncacheable$/\1 \2 \3/p' | tail -n 1
}

# fm_lint_cache_markers <dir>: how many result markers the cache holds.
fm_lint_cache_markers() {
  find "$1" -maxdepth 1 -type f ! -name '.*' 2>/dev/null | wc -l | tr -d ' '
}

# shellcheck disable=SC2016 # The fixture scripts are written literally, so their $ stay unexpanded.
test_partition_weights_follow_the_source_closure() {
  local tmp repo part parts_of
  tmp=$(fm_test_tmproot fm-lint-weights)
  repo="$tmp/repo"
  fm_lint_cache_repo "$repo"
  # Roots that cost far more than their own bytes because of what they source
  # must be spread across runners; packing on bytes would stack them. Two reach
  # the large library through a source directive chain and a literal source
  # statement. The copied lint owner is a root of the fixture too, so the sizes
  # dwarf it.
  { printf '%s\n' '#!/usr/bin/env bash'; yes '# padding padding padding padding padding padding padding padding' | head -n 3000; } > "$repo/lib/big.sh"
  { printf '%s\n' '#!/usr/bin/env bash'; yes '# padding padding padding padding padding padding padding padding' | head -n 2200; } > "$repo/bin/heavy.sh"
  printf '%s\n' '#!/usr/bin/env bash' '# shellcheck source=lib/big.sh' '. "${1:?}"' > "$repo/lib/mid.sh"
  printf '%s\n' '#!/usr/bin/env bash' '# shellcheck source=lib/mid.sh' '. "${1:?}"' > "$repo/bin/a.sh"
  printf '%s\n' '#!/usr/bin/env bash' '. lib/big.sh' > "$repo/bin/b.sh"
  parts_of=
  for part in 1of2 2of2; do
    CI=true "$repo/bin/fm-lint.sh" --partition "$part" --list-files | grep -qx bin/a.sh && parts_of="$parts_of a=$part"
    CI=true "$repo/bin/fm-lint.sh" --partition "$part" --list-files | grep -qx bin/b.sh && parts_of="$parts_of b=$part"
  done
  case "$parts_of" in
    " a=1of2 b=2of2"|" a=2of2 b=1of2") ;;
    *) fail "roots sharing a large source closure were packed on one runner:$parts_of" ;;
  esac
  pass "partition placement follows the source closure, not the root's own bytes"
}

# shellcheck disable=SC2016 # The fixture scripts are written literally, so their $ stay unexpanded.
test_cache_hit_is_the_same_pass_on_identical_inputs() {
  if ! pinned_ready; then
    pass "SKIP (ShellCheck $REQUIRED not resolved): result cache equivalence check"
    return
  fi
  local tmp repo cache out rc counts
  tmp=$(fm_test_tmproot fm-lint-cache)
  repo="$tmp/repo"
  cache="$tmp/cache"
  fm_lint_cache_repo "$repo"
  printf '%s\n' '#!/usr/bin/env bash' 'leaf_var=1' 'export leaf_var' > "$repo/lib/leaf.sh"
  printf '%s\n' '#!/usr/bin/env bash' '# shellcheck source=lib/leaf.sh' '. "${1:?}"' > "$repo/lib/mid.sh"
  printf '%s\n' '#!/usr/bin/env bash' '# shellcheck source=lib/mid.sh' '. "${1:?}"' \
    'printf "%s\n" "$leaf_var"' > "$repo/bin/root.sh"

  rc=0; out=$(FM_LINT_CACHE_DIR="$cache" "$repo/bin/fm-lint.sh" bin/root.sh 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "the fixture root must pass with its dataflow context: $out"
  [ "$(fm_lint_cache_counts "$out")" = "0 1 0" ] || fail "the first run was not a miss: $out"
  [ "$(fm_lint_cache_markers "$cache")" = 1 ] || fail "a passing root left no cache marker"

  rc=0; out=$(FM_LINT_CACHE_DIR="$cache" "$repo/bin/fm-lint.sh" bin/root.sh 2>&1) || rc=$?
  [ "$rc" -eq 0 ] && [ "$(fm_lint_cache_counts "$out")" = "1 0 0" ] \
    || fail "identical inputs did not hit the cache: $out"

  # The dataflow fact the root depends on lives two sources deep. If ShellCheck
  # did not follow the chain this change could not alter the root's result, and
  # a stale pass would be indistinguishable from a correct one.
  printf '%s\n' '#!/usr/bin/env bash' 'other_var=1' 'export other_var' > "$repo/lib/leaf.sh"
  rc=0; out=$(FM_LINT_CACHE_DIR="$cache" "$repo/bin/fm-lint.sh" bin/root.sh 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a change two sources deep that breaks the root was served from the cache"
  assert_contains "$out" "SC2154" "the transitive change did not reach ShellCheck's dataflow"
  [ "$(fm_lint_cache_counts "$out")" = "0 1 0" ] || fail "the changed closure was not a miss: $out"

  # Findings are never stored, so the same defect fails again.
  rc=0; out=$(FM_LINT_CACHE_DIR="$cache" "$repo/bin/fm-lint.sh" bin/root.sh 2>&1) || rc=$?
  [ "$rc" -ne 0 ] && [ "$(fm_lint_cache_counts "$out")" = "0 1 0" ] \
    || fail "a failing root was cached: $out"
  [ "$(fm_lint_cache_markers "$cache")" = 1 ] || fail "a failing root left a marker"

  # Restoring the exact bytes is a hit again: the entry is content addressed.
  printf '%s\n' '#!/usr/bin/env bash' 'leaf_var=1' 'export leaf_var' > "$repo/lib/leaf.sh"
  counts=$(fm_lint_cache_counts "$(FM_LINT_CACHE_DIR="$cache" "$repo/bin/fm-lint.sh" bin/root.sh 2>&1)")
  [ "$counts" = "1 0 0" ] || fail "restored bytes did not hit the cache: $counts"

  # A different analysis mode, a changed root and a changed lint definition each miss.
  counts=$(fm_lint_cache_counts "$(env -u CI -u GITHUB_ACTIONS FM_LINT_CACHE_DIR="$cache" "$repo/bin/fm-lint.sh" --fast bin/root.sh 2>&1)")
  [ "$counts" = "0 1 0" ] || fail "fast mode reused a full-analysis pass: $counts"
  printf '# edited\n' >> "$repo/bin/root.sh"
  counts=$(fm_lint_cache_counts "$(FM_LINT_CACHE_DIR="$cache" "$repo/bin/fm-lint.sh" bin/root.sh 2>&1)")
  [ "$counts" = "0 1 0" ] || fail "an edited root hit the cache: $counts"
  printf '# edited lint definition\n' >> "$repo/bin/fm-lint.sh"
  counts=$(fm_lint_cache_counts "$(FM_LINT_CACHE_DIR="$cache" "$repo/bin/fm-lint.sh" bin/root.sh 2>&1)")
  [ "$counts" = "0 1 0" ] || fail "an edited lint definition reused an older pass: $counts"
  pass "a cache hit is the same pass on identical inputs, including bytes two sources deep"
}

# shellcheck disable=SC2016 # The fixture scripts are written literally, so their $ stay unexpanded.
test_cache_missing_source_target_is_part_of_the_key() {
  if ! pinned_ready; then
    pass "SKIP (ShellCheck $REQUIRED not resolved): result cache missing-target check"
    return
  fi
  local tmp repo cache out rc
  tmp=$(fm_test_tmproot fm-lint-cache-missing)
  repo="$tmp/repo"
  cache="$tmp/cache"
  fm_lint_cache_repo "$repo"
  printf '%s\n' '#!/usr/bin/env bash' '# shellcheck source=lib/late.sh disable=SC1091' '. "${1:?}"' \
    'printf "%s\n" "${late_var:-}"' > "$repo/bin/root.sh"
  rc=0; out=$(FM_LINT_CACHE_DIR="$cache" "$repo/bin/fm-lint.sh" bin/root.sh 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "the missing-target fixture must pass: $out"
  # Creating the file ShellCheck could not find before changes what it sees.
  printf '%s\n' '#!/usr/bin/env bash' 'late_var=1' 'export late_var' > "$repo/lib/late.sh"
  out=$(FM_LINT_CACHE_DIR="$cache" "$repo/bin/fm-lint.sh" bin/root.sh 2>&1) || true
  [ "$(fm_lint_cache_counts "$out")" = "0 1 0" ] || fail "creating a missing source target hit the cache: $out"
  pass "creating a previously missing source target invalidates the key"
}

# shellcheck disable=SC2016 # The fixture scripts are written literally, so their $ stay unexpanded.
test_cache_never_stores_a_weaker_or_unproven_result() {
  if ! pinned_ready; then
    pass "SKIP (ShellCheck $REQUIRED not resolved): result cache storage rules"
    return
  fi
  local tmp repo cache list out rc fakebin
  tmp=$(fm_test_tmproot fm-lint-cache-rules)
  repo="$tmp/repo"
  cache="$tmp/cache"
  list="$tmp/list"
  fm_lint_cache_repo "$repo"

  # A stale ratchet exception is reported every run and never cached.
  fm_lint_ratchet_fixture "$repo/bin/fixed.sh" passing
  printf 'bin/fixed.sh\n' > "$list"
  for _ in 1 2; do
    rc=0; out=$(FM_LINT_RATCHET_LIST="$list" FM_LINT_CACHE_DIR="$cache" "$repo/bin/fm-lint.sh" bin/fixed.sh 2>&1) || rc=$?
    [ "$rc" -ne 0 ] && [ "$(fm_lint_cache_counts "$out")" = "0 1 0" ] \
      || fail "a stale ratchet exception was served from the cache: $out"
  done
  [ "$(fm_lint_cache_markers "$cache")" = 0 ] || fail "a stale ratchet exception left a marker"

  # Whether a root is on the exception list is part of its key.
  fm_lint_ratchet_fixture "$repo/bin/listed.sh" failing
  printf 'bin/listed.sh\n' > "$list"
  rc=0; out=$(FM_LINT_RATCHET_LIST="$list" FM_LINT_CACHE_DIR="$cache" "$repo/bin/fm-lint.sh" bin/listed.sh 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "a listed failing root must pass: $out"
  : > "$list"
  rc=0; out=$(FM_LINT_RATCHET_LIST="$list" FM_LINT_CACHE_DIR="$cache" "$repo/bin/fm-lint.sh" bin/listed.sh 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "removing a root from the ratchet list still passed from the cache"
  assert_contains "$out" "SC2248" "the ratchet finding did not return once the exception was removed"

  # A root that lints only after the memory fallback ran a weaker check, so it
  # is not stored.
  cache="$tmp/cache-fallback"
  fakebin=$(fm_fakebin "$tmp")
  cat > "$fakebin/shellcheck" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf 'ShellCheck - shell script analysis tool\nversion: 0.11.0\n'
  exit 0
fi
case " $* " in *" --include="*) exit 0 ;; esac
printf 'call\n' >> "$FM_TEST_CALL_LOG"
case " $* " in
  *" --external-sources "*) printf 'shellcheck: Heap exhausted;\n' >&2; exit 251 ;;
esac
exit 0
SH
  chmod +x "$fakebin/shellcheck"
  : > "$tmp/calls"
  for _ in 1 2; do
    rc=0; out=$(PATH="$fakebin:$PATH" FM_TEST_CALL_LOG="$tmp/calls" FM_LINT_CACHE_DIR="$cache" \
      "$repo/bin/fm-lint.sh" bin/fixed.sh 2>&1) || rc=$?
  done
  [ "$(wc -l < "$tmp/calls" | tr -d ' ')" = 4 ] || fail "a memory-fallback root was not re-linted on the second run"
  [ "$(fm_lint_cache_markers "$cache")" = 0 ] || fail "a memory-fallback pass left a marker"

  # A source-path directive adds search directories the closure scan does not
  # model, so such a root is always linted.
  cache="$tmp/cache-searchpath"
  printf '%s\n' '#!/usr/bin/env bash' '# shellcheck source-path=SCRIPTDIR' 'exit 0' > "$repo/bin/searchpath.sh"
  for _ in 1 2; do
    out=$(FM_LINT_CACHE_DIR="$cache" "$repo/bin/fm-lint.sh" bin/searchpath.sh 2>&1) || true
    [ "$(fm_lint_cache_counts "$out")" = "0 0 1" ] || fail "a source-path root was cacheable: $out"
  done
  [ "$(fm_lint_cache_markers "$cache")" = 0 ] || fail "a source-path root left a marker"
  pass "the cache never stores findings, stale exceptions, weaker fallbacks or unmodelled roots"
}

test_cache_unusable_directory_lints_every_root() {
  if ! pinned_ready; then
    pass "SKIP (ShellCheck $REQUIRED not resolved): unusable result cache check"
    return
  fi
  local tmp repo out rc
  tmp=$(fm_test_tmproot fm-lint-cache-off)
  repo="$tmp/repo"
  fm_lint_cache_repo "$repo"
  : > "$tmp/not-a-dir"
  rc=0; out=$(FM_LINT_CACHE_DIR="$tmp/not-a-dir/cache" "$repo/bin/fm-lint.sh" tests/t.sh 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "an unusable cache directory broke the lint: $out"
  assert_contains "$out" "linting every root" "an unusable cache directory was not disclosed"
  [ -z "$(fm_lint_cache_counts "$out")" ] || fail "an unusable cache reported cache results: $out"
  pass "an unusable result cache directory leaves every root linted"
}

test_cache_prune_keeps_only_markers_the_run_used() {
  if ! pinned_ready; then
    pass "SKIP (ShellCheck $REQUIRED not resolved): result cache prune check"
    return
  fi
  local tmp repo cache out rc
  tmp=$(fm_test_tmproot fm-lint-cache-prune)
  repo="$tmp/repo"
  cache="$tmp/cache"
  fm_lint_cache_repo "$repo"
  rc=0; out=$(CI=true FM_LINT_CACHE_DIR="$cache" "$repo/bin/fm-lint.sh" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "the fixture inventory must pass: $out"
  [ "$(fm_lint_cache_counts "$out")" = "0 6 0" ] || fail "the first full run was not six misses: $out"
  [ "$(fm_lint_cache_markers "$cache")" = 6 ] || fail "six passing roots did not leave six markers"
  printf '# edited\n' >> "$repo/tests/t.sh"
  rc=0; out=$(CI=true FM_LINT_CACHE_DIR="$cache" "$repo/bin/fm-lint.sh" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] && [ "$(fm_lint_cache_counts "$out")" = "5 1 0" ] \
    || fail "an edit to one root was not one miss and five hits: $out"
  [ "$(fm_lint_cache_markers "$cache")" = 6 ] || fail "the superseded marker was not pruned"
  # An explicit-path run covers part of a set and never prunes the rest.
  FM_LINT_CACHE_DIR="$cache" "$repo/bin/fm-lint.sh" tests/t.sh >/dev/null 2>&1
  [ "$(fm_lint_cache_markers "$cache")" = 6 ] || fail "a partial run pruned markers it did not own"
  pass "a full passing run prunes superseded markers and a partial run leaves them"
}

test_cache_keep_days_retains_by_age_not_by_use() {
  if ! pinned_ready; then
    pass "SKIP (ShellCheck $REQUIRED not resolved): result cache keep-days check"
    return
  fi
  local tmp repo cache out rc counts
  tmp=$(fm_test_tmproot fm-lint-cache-keep)
  repo="$tmp/repo"
  cache="$tmp/cache"
  fm_lint_cache_repo "$repo"
  rc=0; out=$(CI=true FM_LINT_CACHE_DIR="$cache" FM_LINT_CACHE_KEEP_DAYS=30 "$repo/bin/fm-lint.sh" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] && [ "$(fm_lint_cache_counts "$out")" = "0 6 0" ] \
    || fail "the first full run was not six misses: $out"
  # A second branch edits a root. Its full passing run must not delete the
  # marker the first branch's bytes still need, which the use-based prune does.
  cp "$repo/tests/t.sh" "$tmp/t.sh.first"
  printf '# edited\n' >> "$repo/tests/t.sh"
  rc=0; out=$(CI=true FM_LINT_CACHE_DIR="$cache" FM_LINT_CACHE_KEEP_DAYS=30 "$repo/bin/fm-lint.sh" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] && [ "$(fm_lint_cache_counts "$out")" = "5 1 0" ] \
    || fail "an edit to one root was not one miss and five hits: $out"
  [ "$(fm_lint_cache_markers "$cache")" = 7 ] || fail "keep-days mode pruned a marker that is not old"
  cp "$tmp/t.sh.first" "$repo/tests/t.sh"
  counts=$(fm_lint_cache_counts "$(CI=true FM_LINT_CACHE_DIR="$cache" FM_LINT_CACHE_KEEP_DAYS=30 "$repo/bin/fm-lint.sh" 2>&1)")
  [ "$counts" = "6 0 0" ] || fail "the first branch's bytes did not hit the retained marker: $counts"
  # Age every marker, then run: used markers are refreshed by their hit, the one
  # nothing used stays old and goes.
  printf '# edited again\n' >> "$repo/tests/t.sh"
  find "$cache" -maxdepth 1 -type f -exec touch -t 200001010000 {} +
  rc=0; out=$(CI=true FM_LINT_CACHE_DIR="$cache" FM_LINT_CACHE_KEEP_DAYS=30 "$repo/bin/fm-lint.sh" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] && [ "$(fm_lint_cache_counts "$out")" = "5 1 0" ] \
    || fail "the aged cache did not give five hits and one miss: $out"
  [ "$(fm_lint_cache_markers "$cache")" = 6 ] \
    || fail "an aged marker survived, or a marker a hit refreshed was removed"
  # An unset value keeps the use-based prune and a bad value is refused.
  for bad in 0 abc -3; do
    rc=0; out=$(FM_LINT_CACHE_DIR="$cache" FM_LINT_CACHE_KEEP_DAYS="$bad" "$repo/bin/fm-lint.sh" tests/t.sh 2>&1) || rc=$?
    [ "$rc" -eq 2 ] || fail "FM_LINT_CACHE_KEEP_DAYS=$bad was not refused: rc=$rc $out"
  done
  pass "keep-days mode retains markers by age, refreshes them on a hit and refuses a bad value"
}

# no-mistakes runs commands.lint as `sh -c <command>` (shellenv in no-mistakes
# v1.106.1) from the run worktree. Run the configured string the same way, with
# stub scripts in a scratch tree, and check the variables the documented cache
# contract names reach fm-lint.sh.
test_no_mistakes_lint_command_enables_the_keep_days_cache() {
  command -v ruby >/dev/null 2>&1 \
    || fail "ruby is required to parse .no-mistakes.yaml for this check"
  local tmp tree cmd got rc
  tmp=$(fm_test_tmproot fm-lint-nm-wiring)
  tree="$tmp/tree"
  mkdir -p "$tree/bin" "$tree/tests" "$tmp/home" "$tmp/xdg"
  cmd=$(ruby -ryaml -e 'print((YAML.load_file(ARGV[0])["commands"] || {})["lint"].to_s)' "$ROOT/.no-mistakes.yaml") \
    || fail "failed to parse .no-mistakes.yaml as YAML"
  [ -n "$cmd" ] || fail ".no-mistakes.yaml has no commands.lint"
  printf '#!/bin/sh\nexit 0\n' > "$tree/bin/fm-secret-scan.sh"
  cat > "$tree/bin/fm-lint.sh" <<'SH'
#!/bin/sh
printf '%s|%s\n' "${FM_LINT_CACHE_DIR-unset}" "${FM_LINT_CACHE_KEEP_DAYS-unset}" > "$FM_LINT_WIRING_SEEN"
SH
  printf 'exit 0\n' > "$tree/tests/fm-pi-primary-types.test.sh"
  chmod +x "$tree/bin/fm-secret-scan.sh" "$tree/bin/fm-lint.sh"
  rc=0; (cd "$tree" && env -u XDG_CACHE_HOME HOME="$tmp/home" FM_LINT_WIRING_SEEN="$tmp/seen" sh -c "$cmd") || rc=$?
  got=$(cat "$tmp/seen" 2>/dev/null)
  [ "$rc" -eq 0 ] && [ "$got" = "$tmp/home/.cache/fm-lint|30" ] \
    || fail "commands.lint without XDG_CACHE_HOME gave rc=$rc and '$got', not '$tmp/home/.cache/fm-lint|30'"
  : > "$tmp/seen"
  rc=0; (cd "$tree" && HOME="$tmp/home" XDG_CACHE_HOME="$tmp/xdg" FM_LINT_WIRING_SEEN="$tmp/seen" sh -c "$cmd") || rc=$?
  got=$(cat "$tmp/seen")
  [ "$rc" -eq 0 ] && [ "$got" = "$tmp/xdg/fm-lint|30" ] \
    || fail "commands.lint with XDG_CACHE_HOME gave rc=$rc and '$got', not '$tmp/xdg/fm-lint|30'"
  pass "the no-mistakes lint command runs fm-lint.sh with the cache directory and FM_LINT_CACHE_KEEP_DAYS=30"
}

test_seeded_module_boundary_parity() {
  if ! pinned_ready; then
    pass "SKIP (ShellCheck $REQUIRED not resolved): seeded source-boundary parity check"
    return
  fi
  local tmp adapter dispatcher dep owner test_root out rc
  tmp=$(fm_test_tmproot fm-lint-parity)
  adapter="$tmp/adapter.sh"
  dispatcher="$tmp/dispatcher.sh"
  dep="$tmp/owner-dep.sh"
  owner="$tmp/owner.sh"
  test_root="$tmp/test-local.sh"

  cat > "$adapter" <<'SH'
#!/usr/bin/env bash
adapter_bad() {
  rm $1
}
SH
  cat > "$dispatcher" <<SH
#!/usr/bin/env bash
# shellcheck source=/dev/null
. "$adapter"
dispatcher_bad() {
  local a= b=
  printf '%s\n' "\$a\$b"
}
SH
  cat > "$dep" <<'SH'
#!/usr/bin/env bash
owner_dependency_value=ok
SH
  cat > "$owner" <<SH
#!/usr/bin/env bash
# shellcheck source=$dep
. "$dep"
owner_bad() {
  printf '%s\n' "\$owner_dependency_value"
  cd "\$1"
}
SH
  cat > "$test_root" <<SH
#!/usr/bin/env bash
# shellcheck source=/dev/null
. "$owner"
test_local_bad() {
  local output=\$(printf ok)
  printf '%s\n' "\$output"
}
SH

  rc=0
  out=$(FM_LINT_JOBS=2 "$LINT" "$dispatcher" "$adapter" "$owner" "$test_root" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "seeded module-boundary defects unexpectedly passed"
  assert_contains "$out" "SC1007" "representative dispatcher defect was hidden"
  assert_contains "$out" "SC2086" "representative canonical adapter defect was hidden"
  assert_contains "$out" "SC2164" "representative production-owner defect was hidden"
  assert_contains "$out" "SC2155" "representative test-local defect was hidden"
  assert_not_contains "$out" "SC2154" "the production owner lost source-aware dependency context"
  [ "$(printf '%s\n' "$out" | grep -Fc 'SC2086 (info)')" -eq 1 ] \
    || fail "the dispatcher boundary re-imported the adapter diagnostic"
  [ "$(printf '%s\n' "$out" | grep -Fc 'SC2164 (warning)')" -eq 1 ] \
    || fail "the test boundary re-imported the production-owner diagnostic"
  pass "seeded dispatcher, adapter, production-owner, and test-local diagnostics preserve parity"
}

test_help_reports_the_complete_interface
test_list_files_reports_the_shell_inventory
test_canonical_partitions_preserve_full_lint
test_fast_mode_disables_extended_analysis
test_ci_defaults_to_full_analysis
test_ci_rejects_explicit_fast_mode
test_fast_mode_catches_a_real_lint_defect
test_pins_an_explicit_version
test_installer_retries_transient_download_failure
test_installer_skips_download_when_pinned_binary_is_present
test_installer_selects_platform_archive_url_and_checksum
test_installer_rejects_wrong_checksum
test_installer_falls_back_to_shasum
test_installer_prefers_sha256sum_over_shasum
test_installer_rejects_unsupported_platform
test_missing_shellcheck_fails_closed
test_rejects_wrong_shellcheck_version
test_catches_a_real_lint_defect
test_rejects_direct_beads_cli_invocations
test_rejects_direct_beads_cli_in_explicit_core_path
test_ratchet_skips_listed_files_and_fails_unlisted_ones
test_ratchet_reports_a_listed_file_that_now_passes
test_ratchet_tool_failure_is_not_a_stale_entry
test_ratchet_shares_the_roots_one_deadline
test_ratchet_helper_retires_one_file_at_a_time
test_ignores_ambient_shellcheck_opts
test_clean_fixture_passes
test_jobs_are_deterministic_and_complete
test_worker_trees_stop_on_signal
test_root_deadline_names_the_root_and_reaps_the_tree
test_root_memory_limit_reports_a_named_death
test_memory_cap_wraps_each_root_in_a_capped_scope
test_memory_cap_unavailable_says_so_once_and_still_lints
test_memory_cap_kill_is_a_named_memory_limit_not_a_finding
test_memory_cap_real_scope_kills_only_the_hoarder
test_memory_failure_retries_without_external_sources
test_memory_fallback_spends_only_the_remaining_root_deadline
test_memory_evidence_outranks_findings_and_signal_reasons
test_source_excerpt_with_oom_text_stays_findings
test_require_bounds_refuses_when_enforcement_is_missing
test_pinned_shellcheck_memory_limit
test_sidecar_result_exit_reflects_final_status
test_roots_sidecar_records_per_root_lifecycle
test_partition_weights_follow_the_source_closure
test_cache_hit_is_the_same_pass_on_identical_inputs
test_cache_missing_source_target_is_part_of_the_key
test_cache_never_stores_a_weaker_or_unproven_result
test_cache_unusable_directory_lints_every_root
test_cache_prune_keeps_only_markers_the_run_used
test_cache_keep_days_retains_by_age_not_by_use
test_no_mistakes_lint_command_enables_the_keep_days_cache
test_seeded_module_boundary_parity
test_changed_mode_lints_only_the_changed_file
test_ci_forces_full_lint_even_with_empty_diff
test_main_branch_forces_full_lint
test_explicit_path_bypasses_changed_logic
test_zero_changed_files_exits_clean
test_list_files_respects_changed_mode
test_changed_mode_drops_external_sources_and_excludes_cross_file_codes
test_changed_mode_invokes_shellcheck_once_per_root
test_ci_keeps_external_sources_without_local_exclusions
test_main_branch_keeps_external_sources
test_merge_base_less_keeps_external_sources
test_explicit_path_keeps_external_sources
test_fast_mode_on_a_local_branch_keeps_source_following
test_changed_mode_hides_cross_file_codes_that_ci_still_sees
test_changed_flag_keeps_source_following_in_ci
test_changed_flag_upgrades_when_lint_definition_changes
test_changed_flag_upgrades_when_a_sourced_helper_changes
test_changed_flag_upgrades_when_a_sourced_helper_is_deleted
test_changed_flag_upgrades_when_a_sourced_helper_is_renamed
test_changed_flag_upgrades_when_a_lint_definition_is_renamed
test_empty_changed_partition_is_a_successful_noop
test_local_exclusion_list_covers_every_no_external_sources_code
