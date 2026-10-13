#!/usr/bin/env bash
# fm-install-pinned.sh - install a pinned, checksum-verified release binary.
#
# Usage: fm-install-pinned.sh treehouse|no-mistakes
#
# Downloads the exact release asset named by bin/fm-install-pins.sh (never a
# branch or "latest"), verifies its SHA-256 against the pin before extracting,
# and refuses with exit 1 on any mismatch. Install locations mirror the
# upstream installers: treehouse goes to ~/.local/bin when that is on PATH, else
# /usr/local/bin (sudo if needed); no-mistakes goes to $NO_MISTAKES_INSTALL_DIR
# (default ~/.no-mistakes/bin) with a symlink in $NO_MISTAKES_LINK_DIR and a
# daemon restart.
# Test hooks: FM_INSTALL_PINS_FILE replaces the pins file,
# FM_INSTALL_RELEASE_BASE replaces https://github.com/<repo>/releases/download,
# FM_INSTALL_TREEHOUSE_DIR replaces the treehouse install directory.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-install-pins.sh disable=SC1091
. "${FM_INSTALL_PINS_FILE:-$SCRIPT_DIR/fm-install-pins.sh}"

die() {
  printf 'fm-install-pinned.sh: %s\n' "$*" >&2
  exit 1
}

tool=${1:-}
os=$(uname -s | tr '[:upper:]' '[:lower:]')
case "$(uname -m)" in
  x86_64|amd64) arch=amd64 ;;
  arm64|aarch64) arch=arm64 ;;
  *) die "unsupported architecture: $(uname -m)" ;;
esac
case "$os" in darwin|linux) ;; *) die "unsupported OS: $os" ;; esac

expected=""
case "${tool}-${os}-${arch}" in
  treehouse-*) repo=kunchenguid/treehouse; version=$FM_PIN_TREEHOUSE_VERSION ;;
  no-mistakes-*) repo=kunchenguid/no-mistakes; version=$FM_PIN_NO_MISTAKES_VERSION ;;
  *) die "usage: fm-install-pinned.sh treehouse|no-mistakes" ;;
esac
case "${tool}-${os}-${arch}" in
  treehouse-darwin-amd64) expected=${FM_PIN_TREEHOUSE_SHA256_darwin_amd64:-} ;;
  treehouse-darwin-arm64) expected=${FM_PIN_TREEHOUSE_SHA256_darwin_arm64:-} ;;
  treehouse-linux-amd64) expected=${FM_PIN_TREEHOUSE_SHA256_linux_amd64:-} ;;
  treehouse-linux-arm64) expected=${FM_PIN_TREEHOUSE_SHA256_linux_arm64:-} ;;
  no-mistakes-darwin-amd64) expected=${FM_PIN_NO_MISTAKES_SHA256_darwin_amd64:-} ;;
  no-mistakes-darwin-arm64) expected=${FM_PIN_NO_MISTAKES_SHA256_darwin_arm64:-} ;;
  no-mistakes-linux-amd64) expected=${FM_PIN_NO_MISTAKES_SHA256_linux_amd64:-} ;;
  no-mistakes-linux-arm64) expected=${FM_PIN_NO_MISTAKES_SHA256_linux_arm64:-} ;;
esac
[ -n "$expected" ] || die "no pinned checksum for $tool on ${os}/${arch}"

archive="${tool}-v${version}-${os}-${arch}.tar.gz"
url="${FM_INSTALL_RELEASE_BASE:-https://github.com/$repo/releases/download}/v${version}/${archive}"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-install-pinned.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

echo "downloading $tool v$version from $url"
curl -fsSL "$url" -o "$tmp/$archive" || die "download failed for $url"

if command -v sha256sum >/dev/null 2>&1; then
  actual=$(sha256sum "$tmp/$archive" | awk '{print $1}')
elif command -v shasum >/dev/null 2>&1; then
  actual=$(shasum -a 256 "$tmp/$archive" | awk '{print $1}')
else
  die "need sha256sum or shasum to verify $archive"
fi
[ "$actual" = "$expected" ] || die "checksum mismatch for $archive (expected $expected, got $actual); refusing to install"

tar xzf "$tmp/$archive" -C "$tmp" "$tool" || die "archive $archive did not contain $tool"

if [ "$tool" = treehouse ]; then
  if [ -n "${FM_INSTALL_TREEHOUSE_DIR:-}" ]; then
    dir=$FM_INSTALL_TREEHOUSE_DIR
  elif echo "$PATH" | tr ':' '\n' | grep -qx "$HOME/.local/bin"; then
    dir=$HOME/.local/bin
  else
    dir=/usr/local/bin
  fi
  if mkdir -p "$dir" 2>/dev/null && [ -w "$dir" ]; then
    install -m 0755 "$tmp/treehouse" "$dir/treehouse"
  else
    echo "installing to $dir (requires sudo)"
    sudo mkdir -p "$dir"
    sudo install -m 0755 "$tmp/treehouse" "$dir/treehouse"
  fi
  echo "treehouse v$version installed to $dir/treehouse"
  exit 0
fi

install_dir=${NO_MISTAKES_INSTALL_DIR:-$HOME/.no-mistakes/bin}
link_dir=${NO_MISTAKES_LINK_DIR:-}
if [ -z "$link_dir" ]; then
  case ":$PATH:" in
    *":$HOME/.local/bin:"*) link_dir=$HOME/.local/bin ;;
    *) link_dir=/usr/local/bin ;;
  esac
fi
mkdir -p "$install_dir" || die "could not create install directory: $install_dir"
install -m 0755 "$tmp/no-mistakes" "$install_dir/no-mistakes"
real_install=$(cd "$install_dir" && pwd -P)
real_link=$(cd "$link_dir" 2>/dev/null && pwd -P || true)
if [ "$real_install" != "$real_link" ]; then
  if mkdir -p "$link_dir" 2>/dev/null && [ -w "$link_dir" ]; then
    ln -sf "$install_dir/no-mistakes" "$link_dir/no-mistakes"
  else
    echo "linking into $link_dir (requires sudo)"
    sudo mkdir -p "$link_dir"
    sudo ln -sf "$install_dir/no-mistakes" "$link_dir/no-mistakes"
  fi
fi
echo "no-mistakes v$version installed to $install_dir/no-mistakes"
"$install_dir/no-mistakes" daemon restart >/dev/null
