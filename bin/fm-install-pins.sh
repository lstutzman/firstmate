# shellcheck shell=bash
# fm-install-pins.sh - the single place fleet bootstrap installs are pinned.
#
# Sourced by fm-bootstrap.sh (npm pins) and fm-install-pinned.sh (release
# binaries). To bump a tool, edit its version here; for treehouse and
# no-mistakes also replace the four SHA-256 values from the release's
# checksums.txt (https://github.com/<repo>/releases/download/<tag>/checksums.txt).
# A version bump without matching checksums makes the installer refuse.

FM_PIN_TREEHOUSE_VERSION=3.1.1
FM_PIN_TREEHOUSE_SHA256_darwin_amd64=7be948dcbd0da771fea6938c11f994b909ea8b440f8ae29aa2fddb6020fdebff
FM_PIN_TREEHOUSE_SHA256_darwin_arm64=79926e73e420560eeee2ca1b3bd2a26f7aeca8f0122ddff79c909fa48342976a
FM_PIN_TREEHOUSE_SHA256_linux_amd64=e469b7bdeaae2416fea49993255a02e369b9e213390ddd04bf053f4834fe3d3a
FM_PIN_TREEHOUSE_SHA256_linux_arm64=4f1a6d8ec274b667b31052cb49f7c0c02b90053c2d284e33d4c3ab968aae6436

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
