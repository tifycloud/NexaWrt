#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAGE_SCRIPT="$ROOT_DIR/scripts/stage-nss-artifact.sh"
EXPECTED_IMAGE="openwrt-qualcommax-ipq807x-xiaomi_ax9000_single_ubi-initramfs-uImage.itb"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  echo "test_nss_artifact_policy: $*" >&2
  exit 1
}

new_fixture() {
  fixture="$TMP_DIR/$1"
  bin_dir="$fixture/work/bin/targets/qualcommax/ipq807x"
  dist_dir="$fixture/dist-nss"
  mkdir -p "$bin_dir"
  printf 'test initramfs\n' > "$bin_dir/$EXPECTED_IMAGE"
  printf 'config metadata\n' > "$bin_dir/config.buildinfo"
  printf 'feed metadata\n' > "$bin_dir/feeds.buildinfo"
  printf '{}\n' > "$bin_dir/profiles.json"
  printf 'version metadata\n' > "$bin_dir/version.buildinfo"
}

new_fixture success
NEXAWRT_FLAVOR=nss WORK_DIR="$fixture/work" DIST_NSS_DIR_OVERRIDE="$dist_dir" \
  "$STAGE_SCRIPT" >/dev/null

[[ -f "$dist_dir/$EXPECTED_IMAGE" ]] || fail "expected initramfs ITB was not staged"
[[ -f "$dist_dir/BUILD-MANIFEST.txt" ]] || fail "BUILD-MANIFEST.txt missing"
[[ -f "$dist_dir/DO-NOT-FLASH.txt" ]] || fail "DO-NOT-FLASH.txt missing"
[[ -f "$dist_dir/THIRD_PARTY_NOTICES.md" ]] || fail "THIRD_PARTY_NOTICES.md missing"
[[ -f "$dist_dir/LICENSES/nss-firmware/LICENSE.md" ]] || fail "firmware license missing"
[[ -f "$dist_dir/SHA256SUMS" ]] || fail "SHA256SUMS missing"
grep -Fxq 'flavor=nss' "$dist_dir/BUILD-MANIFEST.txt" || fail "manifest flavor missing"
grep -Fxq 'stage=initramfs-ram-boot-only' "$dist_dir/BUILD-MANIFEST.txt" || fail "manifest stage missing"
grep -Fxq 'real_device_boot_approved=no' "$dist_dir/BUILD-MANIFEST.txt" || fail "manifest approval boundary missing"
grep -Fxq 'source_repository=https://github.com/qosmio/openwrt-ipq.git' "$dist_dir/BUILD-MANIFEST.txt" || fail "manifest source repository missing"
grep -Fxq 'source_branch=25.12-nss' "$dist_dir/BUILD-MANIFEST.txt" || fail "manifest source branch missing"
grep -Fxq 'source_commit=d6848fa2ea00193b5b7d3973e3990da7f608027c' "$dist_dir/BUILD-MANIFEST.txt" || fail "manifest source commit missing"
grep -Fxq 'nss_packages_feed_commit=0d970dbf0185e3f53709bd803e8a466598023c57' "$dist_dir/BUILD-MANIFEST.txt" || fail "NSS package feed commit missing"
grep -Fxq 'nss_sqm_feed_commit=4b4ed8639229be5e70cf94b73cdf7dbc09e66d5d' "$dist_dir/BUILD-MANIFEST.txt" || fail "NSS SQM feed commit missing"
(
  cd "$dist_dir"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -c SHA256SUMS >/dev/null
  else
    shasum -a 256 -c SHA256SUMS >/dev/null
  fi
) || fail "SHA256SUMS verification failed"

staged_images="$(find "$dist_dir" -type f \( -name '*.bin' -o -name '*.img' -o -name '*.itb' -o -name '*.ubi' \) -print)"
[[ "$staged_images" == "$dist_dir/$EXPECTED_IMAGE" ]] || fail "staging contains a non-allowlisted image"

for extension in bin img itb; do
  new_fixture "unknown-$extension"
  printf 'unexpected image\n' > "$bin_dir/unknown-firmware.$extension"
  if NEXAWRT_FLAVOR=nss WORK_DIR="$fixture/work" DIST_NSS_DIR_OVERRIDE="$dist_dir" \
    "$STAGE_SCRIPT" >/dev/null 2>&1; then
    fail "unknown .$extension artifact was accepted"
  fi
done

for forbidden in ax9000-sysupgrade.bin ax9000-factory.img ax9000-rootfs.ubi; do
  new_fixture "forbidden-${forbidden//[^A-Za-z0-9]/-}"
  printf 'forbidden image\n' > "$bin_dir/$forbidden"
  if NEXAWRT_FLAVOR=nss WORK_DIR="$fixture/work" DIST_NSS_DIR_OVERRIDE="$dist_dir" \
    "$STAGE_SCRIPT" >/dev/null 2>&1; then
    fail "$forbidden was accepted"
  fi
done

new_fixture wrong-flavor
if NEXAWRT_FLAVOR=official WORK_DIR="$fixture/work" DIST_NSS_DIR_OVERRIDE="$dist_dir" \
  "$STAGE_SCRIPT" >/dev/null 2>&1; then
  fail "official flavor entered NSS staging"
fi

new_fixture unsafe-staging-path
if NEXAWRT_FLAVOR=nss WORK_DIR="$fixture/work" DIST_NSS_DIR_OVERRIDE="$fixture/not-dist" \
  "$STAGE_SCRIPT" >/dev/null 2>&1; then
  fail "unsafe non-dist-nss staging path was accepted"
fi

printf 'NSS artifact allowlist staging policy: OK\n'
