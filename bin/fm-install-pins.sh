# shellcheck shell=bash
# fm-install-pins.sh - the single place fleet bootstrap installs are pinned.
#
# Sourced by fm-bootstrap.sh (npm pins) and fm-install-pinned.sh (release
# binaries). To bump a tool, edit its version here; for treehouse and
# no-mistakes also replace the four SHA-256 values from the release's
# checksums.txt (https://github.com/<repo>/releases/download/<tag>/checksums.txt).
# A version bump without matching checksums makes the installer refuse.

# shellcheck disable=SC2034 # Pins are read by the sourcing installers.
FM_PIN_TREEHOUSE_VERSION=3.1.8
FM_PIN_TREEHOUSE_SHA256_darwin_amd64=6be7f71cc8c6a1fbf40311af8ee3c45459c72afbab2c93dc2f80a183427bcbeb
FM_PIN_TREEHOUSE_SHA256_darwin_arm64=007c55c26e0bd8b672b1a917465f06c3f89d93a66cd171364ffb65743d268601
FM_PIN_TREEHOUSE_SHA256_linux_amd64=bd6227d909ba8046263ae5d4e072ccbcf43010cac9d7289b1262126510edfeed
FM_PIN_TREEHOUSE_SHA256_linux_arm64=3d1c02c8ab13049709ace66be51d99b72fe7b6d0b73d0d0efd90f226e1aa87d1

FM_PIN_NO_MISTAKES_VERSION=1.88.0
FM_PIN_NO_MISTAKES_SHA256_darwin_amd64=fc6294fb94ca28ee1c6ba09d0a12191535c6976a1f5b1cfc4a29846648b9e204
FM_PIN_NO_MISTAKES_SHA256_darwin_arm64=d8525e8dfc9b0bf27bdb3fe432d271b3ede7754eba34d3f110b5a33add93f865
FM_PIN_NO_MISTAKES_SHA256_linux_amd64=63fd3aaed4fdabc0d9eaafef5f0720a9711f276f22a02d3d0dde0aa0e309a5ef
FM_PIN_NO_MISTAKES_SHA256_linux_arm64=f816a6dd4b0b67b9e2a22add3adc5ac0ac4e77431d1997059e19eff4e162d969

FM_PIN_GH_AXI_VERSION=0.1.38
FM_PIN_CHROME_DEVTOOLS_AXI_VERSION=0.1.40
FM_PIN_LAVISH_AXI_VERSION=0.1.86
FM_PIN_TASKS_AXI_VERSION=0.2.6
FM_PIN_QUOTA_AXI_VERSION=0.1.60
