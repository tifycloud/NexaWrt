#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SOURCE_STAGE_SCRIPT="$ROOT_DIR/scripts/release.sh"
EXPECTED_IMAGE="openwrt-qualcommax-ipq807x-xiaomi_ax9000_single_ubi-initramfs-uImage.itb"
EXPECTED_MANIFEST="openwrt-qualcommax-ipq807x-xiaomi_ax9000_single_ubi.manifest"
EXPECTED_SBOM="openwrt-qualcommax-ipq807x-xiaomi_ax9000_single_ubi.bom.cdx.json"
mkdir -p "$ROOT_DIR/.work"
TMP_DIR="$(mktemp -d "$ROOT_DIR/.work/test-release-policy.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT
fail() { echo "test_release_policy: $*" >&2; exit 1; }

install_harness_scripts() {
  mkdir -p "$harness/scripts" "$harness/manifests"
  cp "$SOURCE_STAGE_SCRIPT" "$harness/scripts/release.sh"
  cat > "$harness/scripts/validate.sh" <<'VALIDATE'
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
[[ "${NEXAWRT_FLAVOR:-}" == official ]]
[[ "$#" == 3 && "$1" == --source && "$3" == --artifacts ]]
[[ "$(cd "$2" && pwd -P)" == "$(cd "$ROOT/work" && pwd -P)" ]]
touch "$ROOT/validate.called"
VALIDATE
  cat > "$harness/scripts/collect-build-evidence.sh" <<'EVIDENCE'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == official && "$2" == */work && "$3" == */dist && -f "$4" ]]
mkdir -p "$3/EVIDENCE"
printf 'build log\n' > "$3/EVIDENCE/build.log"
printf 'resolved config\n' > "$3/EVIDENCE/resolved.config"
printf 'source state\n' > "$3/EVIDENCE/SOURCE-STATE.txt"
printf 'build environment\n' > "$3/EVIDENCE/BUILD-ENVIRONMENT.txt"
printf 'inputs\n' > "$3/EVIDENCE/INPUTS.sha256"
printf 'evidence checksums\n' > "$3/EVIDENCE/EVIDENCE.sha256"
EVIDENCE
  chmod +x "$harness/scripts/validate.sh" "$harness/scripts/collect-build-evidence.sh"
}

new_fixture() {
  fixture="$TMP_DIR/$1"
  harness="$fixture/project"
  work="$harness/work"
  bin_dir="$work/bin/targets/qualcommax/ipq807x"
  dist_dir="$harness/release-staging/dist"
  build_log="$harness/build.log"
  stage_script="$harness/scripts/release.sh"
  mkdir -p "$bin_dir"
  install_harness_scripts
  printf 'test initramfs\n' > "$bin_dir/$EXPECTED_IMAGE"
  printf 'base-files - 1\n' > "$bin_dir/$EXPECTED_MANIFEST"
  printf '{"bomFormat":"CycloneDX","specVersion":"1.5","components":[{"type":"library","name":"base-files","version":"1"}]}\n' > "$bin_dir/$EXPECTED_SBOM"
  printf 'CONFIG_TARGET_qualcommax=y\n' > "$bin_dir/config.buildinfo"
  printf 'feed metadata\n' > "$bin_dir/feeds.buildinfo"
  printf '{}\n' > "$bin_dir/profiles.json"
  printf 'version metadata\n' > "$bin_dir/version.buildinfo"
  printf 'CONFIG_TARGET_qualcommax=y\n' > "$work/.config"
  printf 'fixture build log\n' > "$build_log"
  git -c init.templateDir= -C "$work" init -q
  git -C "$work" config user.name test
  git -C "$work" config user.email test@example.invalid
  git -C "$work" remote add origin https://git.openwrt.org/openwrt/openwrt.git
  git -C "$work" add .config
  git -C "$work" commit -qm fixture
  locked_commit="$(git -C "$work" rev-parse HEAD)"
  cat > "$harness/manifests/upstream.lock" <<LOCK
OPENWRT_REPO="https://git.openwrt.org/openwrt/openwrt.git"
OPENWRT_TAG="fixture"
OPENWRT_COMMIT="$locked_commit"
LAYOUT_ID="fixture-layout"
ROOTFS_MTD_OFFSET_HEX="0x1"
ROOTFS_MTD_SIZE_HEX="0x2"
LOCK
}

run_stage() {
  NEXAWRT_FLAVOR=official WORK_DIR="$work" BUILD_LOG="$build_log" \
    DIST_DIR_OVERRIDE="$dist_dir" "$stage_script"
}
expect_rejected() {
  local label="$1" expected="$2"
  if run_stage >"$fixture/stdout" 2>"$fixture/stderr"; then fail "$label unexpectedly passed"; fi
  grep -Fq "$expected" "$fixture/stderr" || { cat "$fixture/stderr" >&2; fail "$label failed for an unexpected reason"; }
}

new_fixture success
run_stage >/dev/null
[[ -f "$harness/validate.called" ]] || fail "stage script did not independently invoke validate --source/--artifacts"
for required in "$EXPECTED_IMAGE" "$EXPECTED_MANIFEST" "$EXPECTED_SBOM" BUILD-MANIFEST.txt DO-NOT-FLASH.txt SHA256SUMS EVIDENCE/build.log EVIDENCE/resolved.config EVIDENCE/INPUTS.sha256; do
  [[ -f "$dist_dir/$required" ]] || fail "staged evidence missing: $required"
done
grep -Fxq "source_commit=$locked_commit" "$dist_dir/BUILD-MANIFEST.txt" || fail "manifest is not bound to actual source HEAD"
grep -Fxq 'source_repository=https://git.openwrt.org/openwrt/openwrt.git' "$dist_dir/BUILD-MANIFEST.txt" || fail "manifest is not bound to actual source origin"
(
  cd "$dist_dir"
  if command -v sha256sum >/dev/null 2>&1; then sha256sum -c SHA256SUMS >/dev/null; else shasum -a 256 -c SHA256SUMS >/dev/null; fi
) || fail "SHA256SUMS verification failed"
printf 'tamper\n' >> "$dist_dir/$EXPECTED_IMAGE"
if (cd "$dist_dir" && sha256sum -c SHA256SUMS >/dev/null 2>&1); then fail "checksum tampering was not detected"; fi

for extension in bin img itb ubi; do
  new_fixture "unknown-$extension"; mkdir -p "$bin_dir/nested"; printf bad > "$bin_dir/nested/unknown.$extension"
  expect_rejected "unknown .$extension" "non-allowlisted image artifact present"
done
for forbidden in ax9000-sysupgrade.bin ax9000-factory.img; do
  new_fixture "forbidden-${forbidden//[^A-Za-z0-9]/-}"; printf bad > "$bin_dir/$forbidden"
  expect_rejected "$forbidden" "persistent/installer artifact present"
done
for missing in config.buildinfo feeds.buildinfo profiles.json version.buildinfo "$EXPECTED_MANIFEST" "$EXPECTED_SBOM"; do
  new_fixture "missing-${missing//[^A-Za-z0-9]/-}"; rm "$bin_dir/$missing"
  expect_rejected "missing $missing" "required build evidence is missing: $missing"
done
new_fixture invalid-sbom; printf '{}\n' > "$bin_dir/$EXPECTED_SBOM"; expect_rejected "invalid SBOM" "CycloneDX SBOM is invalid"

new_fixture wrong-head
printf changed > "$work/changed"; git -C "$work" add changed; git -C "$work" commit -qm changed
expect_rejected "wrong source HEAD" "source checkout is not at locked commit"
new_fixture wrong-origin
git -C "$work" remote set-url origin https://example.invalid/openwrt.git
expect_rejected "wrong source origin" "source checkout uses an unexpected origin"

new_fixture outside-path
mkdir -p "$fixture/outside"
dist_dir="$fixture/outside/dist"
expect_rejected "workspace-external staging path" "unsafe staging directory"
new_fixture symlink-path
mkdir -p "$fixture/outside" "$harness/release-staging"
ln -s "$fixture/outside" "$harness/release-staging/dist"
expect_rejected "symlink staging path" "unsafe staging directory"
new_fixture wrong-name
dist_dir="$harness/release-staging/not-dist"
expect_rejected "wrong staging basename" "unsafe staging directory"
new_fixture wrong-flavor
if NEXAWRT_FLAVOR=nss WORK_DIR="$work" BUILD_LOG="$build_log" DIST_DIR_OVERRIDE="$dist_dir" "$stage_script" >/dev/null 2>&1; then
  fail "NSS flavor entered official staging"
fi

official_release="$(make -s -n -C "$ROOT_DIR" release)"
grep -Fq './scripts/release.sh' <<<"$official_release" || fail "Makefile official release target references the wrong staging script"

echo 'official artifact validation binding, safe staging, allowlist, SBOM, evidence, and checksum policy: OK'
