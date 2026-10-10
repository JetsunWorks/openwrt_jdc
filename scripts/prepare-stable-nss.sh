#!/usr/bin/env bash
# Apply a pinned NSS/device delta to the actual ImmortalWrt release tag.
set -euo pipefail

BUILDER_ROOT=$(cd "$(dirname "$0")/.." && pwd)
SOURCE_DIR=${1:?Usage: prepare-stable-nss.sh SOURCE_DIR}
RELEASE_TAG=v25.12.2
RELEASE_SHA=4fc16f2985a358bd43bb522e43f05395fcbd6ed5
NSS_SHA=0a98e096208584bf90982f59f6d5a43f89443276
NSS_FEED_SHA=0b692dc3540321427affe325cd17f14fae8c2133

mkdir -p "$SOURCE_DIR"
cd "$SOURCE_DIR"
if [[ ! -d .git ]]; then
  git init
  git remote add origin https://github.com/immortalwrt/immortalwrt.git
fi
test -z "$(git status --porcelain)"
git fetch --depth 1 origin "refs/tags/$RELEASE_TAG:refs/tags/$RELEASE_TAG"
test "$(git rev-parse "$RELEASE_TAG^{commit}")" = "$RELEASE_SHA"
git checkout --detach "$RELEASE_SHA"
git fetch --depth 1 https://github.com/laipeng668/immortalwrt.git "$NSS_SHA"

# Preserve release userspace, toolchain, generic kernel queues and version defaults.
# Only the NSS driver interfaces, matched Wi-Fi backports/firmware and Qualcomm
# board support are taken from the donor. No Linux 6.18 tree or donor DIY settings.
delta_paths=(
  Config.in config/Config-ipq.in
  target/linux/qualcommax
  package/kernel/mac80211
  package/kernel/cryptodev-linux
  package/kernel/nat46
  package/firmware/ath11k-firmware
  package/firmware/ipq-wifi
  ':(exclude)target/linux/qualcommax/Makefile'
  ':(exclude)target/linux/qualcommax/config-6.18'
  ':(exclude)target/linux/qualcommax/patches-6.18'
  ':(exclude)target/linux/qualcommax/base-files/etc/uci-defaults/991_set-network.sh'
  ':(exclude)target/linux/qualcommax/base-files/etc/uci-defaults/992_set-nss-load.sh'
  ':(exclude)target/linux/qualcommax/base-files/etc/uci-defaults/999_auto-restart.sh'
  ':(exclude)target/linux/qualcommax/base-files/sbin/cpuusage'
)
git diff --binary --no-renames "$RELEASE_SHA" "$NSS_SHA" -- "${delta_paths[@]}" > .nss-release-port.patch
git apply --check .nss-release-port.patch
git apply .nss-release-port.patch
rm .nss-release-port.patch

python3 - "$RELEASE_SHA" "$NSS_FEED_SHA" <<'PY'
import pathlib
import subprocess
import sys

release_sha, nss_feed_sha = sys.argv[1:]
root = pathlib.Path('.')
feeds = root / 'feeds.conf.default'
original = subprocess.check_output(['git', 'show', f'{release_sha}:feeds.conf.default'], text=True)
feeds.write_text(original + f'\nsrc-git nss_packages https://github.com/laipeng668/nss-packages.git^{nss_feed_sha}\n')

# NSS external modules can be rebuilt after a failed compile; reset the temporary
# symbol list each time rather than accumulating stale records.
kernel_mk = root / 'include/kernel.mk'
text = kernel_mk.read_text()
needle = 'define collect_module_symvers\n'
assert text.count(needle) == 1
kernel_mk.write_text(text.replace(needle, needle + '\t: > $(PKG_BUILD_DIR)/Module.symvers.tmp; \\\n', 1))

PY

# Keep official user-space APK feeds, disable incompatible target kmods, and
# enable the image-installed LED service. These scripts are checked in as
# regular files so their syntax can be tested independently.
install -D -m 0755 "$BUILDER_ROOT/scripts/uci-defaults/99-nss-release-feeds" \
  "$SOURCE_DIR/files/etc/uci-defaults/99-nss-release-feeds"
install -D -m 0755 "$BUILDER_ROOT/scripts/uci-defaults/99-athena-led" \
  "$SOURCE_DIR/files/etc/uci-defaults/99-athena-led"

# These files must remain byte-identical to the formal release.
for release_file in include/version.mk target/linux/generic/kernel-6.12; do
  git show "$RELEASE_SHA:$release_file" | cmp - "$release_file"
done
grep -Fxq 'LINUX_VERSION-6.12 = .103' target/linux/generic/kernel-6.12
grep -Fq '),25.12.2)' include/version.mk
test -s target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/ipq6010-re-cs-02.dts
test -s package/kernel/mac80211/patches/nss/ath11k/199-003-ath11k-add-nss-support.patch

mkdir -p "$BUILDER_ROOT/artifacts/diagnostics"
{
  printf 'Release: %s\nRelease commit: %s\nNSS donor: %s\nNSS feed: %s\n' \
    "$RELEASE_TAG" "$RELEASE_SHA" "$NSS_SHA" "$NSS_FEED_SHA"
  printf 'Kernel: 6.12.103 (official release pin retained)\n'
  printf 'Wireless: donor backports 7.2 + ath11k NSS and matched firmware\n'
  printf 'Distribution: custom NSS build based on the formal ImmortalWrt release\n'
  printf 'Official userspace feeds retained; official target/kernel feed disabled.\n'
  git diff --stat
} > "$BUILDER_ROOT/artifacts/diagnostics/SOURCES.txt"
git diff --binary > "$BUILDER_ROOT/artifacts/diagnostics/stable-nss-port.patch"
cp feeds.conf.default "$BUILDER_ROOT/artifacts/diagnostics/feeds.conf"

