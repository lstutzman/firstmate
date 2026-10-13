#!/usr/bin/env bash
# Behavior tests for fm-install-pinned.sh: a pinned release archive installs
# only when its SHA-256 matches the pin; any mismatch refuses and installs nothing.
# A local file:// release base and a generated pins file stand in for GitHub.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-install-pinned-tests)

sha_of() { shasum -a 256 "$1" | awk '{print $1}'; }

# make_case <dir> <tool> <good|bad>: builds a fake release tree and pins file.
make_case() {
  local dir=$1 tool=$2 sum_kind=$3 os arch version=9.9.9 archive sum
  os=$(uname -s | tr '[:upper:]' '[:lower:]')
  case "$(uname -m)" in x86_64|amd64) arch=amd64 ;; *) arch=arm64 ;; esac
  mkdir -p "$dir/stage" "$dir/release/v$version"
  printf '#!/bin/sh\necho fake-%s\n' "$tool" > "$dir/stage/$tool"
  chmod +x "$dir/stage/$tool"
  archive="$tool-v$version-$os-$arch.tar.gz"
  tar czf "$dir/release/v$version/$archive" -C "$dir/stage" "$tool"
  sum=$(sha_of "$dir/release/v$version/$archive")
  [ "$sum_kind" = good ] || sum=0000000000000000000000000000000000000000000000000000000000000000
  {
    printf 'FM_PIN_TREEHOUSE_VERSION=%s\nFM_PIN_NO_MISTAKES_VERSION=%s\n' "$version" "$version"
    for t in TREEHOUSE NO_MISTAKES; do
      for p in darwin_amd64 darwin_arm64 linux_amd64 linux_arm64; do
        printf 'FM_PIN_%s_SHA256_%s=%s\n' "$t" "$p" "$sum"
      done
    done
  } > "$dir/pins.sh"
}

run_installer() {  # <dir> <tool>
  local dir=$1 tool=$2
  FM_INSTALL_PINS_FILE="$dir/pins.sh" FM_INSTALL_RELEASE_BASE="file://$dir/release" \
    FM_INSTALL_TREEHOUSE_DIR="$dir/th-bin" NO_MISTAKES_INSTALL_DIR="$dir/nm-bin" \
    NO_MISTAKES_LINK_DIR="$dir/link" HOME="$dir/home" \
    "$ROOT/bin/fm-install-pinned.sh" "$tool" 2>&1
}

test_installs_treehouse_when_checksum_matches() {
  local d=$TMP_ROOT/th-good out
  make_case "$d" treehouse good
  out=$(run_installer "$d" treehouse) || fail "good treehouse install failed: $out"
  [ "$("$d/th-bin/treehouse")" = fake-treehouse ] || fail "treehouse binary not installed"
  pass "installs treehouse when the checksum matches"
}

test_installs_no_mistakes_and_links_it() {
  local d=$TMP_ROOT/nm-good out
  make_case "$d" no-mistakes good
  out=$(run_installer "$d" no-mistakes) || fail "good no-mistakes install failed: $out"
  [ "$("$d/link/no-mistakes")" = fake-no-mistakes ] || fail "no-mistakes link not usable"
  pass "installs no-mistakes and links it"
}

test_refuses_checksum_mismatch() {
  local tool d out rc
  for tool in treehouse no-mistakes; do
    d=$TMP_ROOT/bad-$tool
    make_case "$d" "$tool" bad
    out=$(run_installer "$d" "$tool"); rc=$?
    [ "$rc" -ne 0 ] || fail "$tool: mismatch must exit non-zero"
    printf '%s' "$out" | grep -q "checksum mismatch" || fail "$tool: missing mismatch message: $out"
    [ ! -e "$d/th-bin/treehouse" ] && [ ! -e "$d/nm-bin/no-mistakes" ] || fail "$tool: installed despite mismatch"
  done
  pass "refuses to install on checksum mismatch"
}

test_rejects_unknown_tool() {
  local out rc
  out=$("$ROOT/bin/fm-install-pinned.sh" bogus 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "unknown tool must fail"
  pass "rejects an unknown tool"
}

test_installs_treehouse_when_checksum_matches
test_installs_no_mistakes_and_links_it
test_refuses_checksum_mismatch
test_rejects_unknown_tool
