#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/nexawrt-session.XXXXXX")"
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "test_create_hardware_session: $*" >&2; exit 1; }
expect_failure() { local label="$1"; shift; if "$@" >/dev/null 2>&1; then fail "$label unexpectedly passed"; fi; }

PROJECT="$TMP/project"
mkdir -p "$PROJECT/scripts" "$PROJECT/release-staging"
cp "$ROOT_DIR/scripts/compare-reproducible-builds.sh" "$PROJECT/scripts/"
copy_build_inputs() {
  local flavor file
  for flavor in official nss; do
    while IFS= read -r -d '' file; do
      mkdir -p "$PROJECT/$(dirname "$file")"
      cp "$ROOT_DIR/$file" "$PROJECT/$file"
    done < <("$ROOT_DIR/scripts/list-build-inputs.sh" "$flavor")
  done
}
copy_build_inputs
cp "$ROOT_DIR/scripts/create-hardware-session.sh" "$PROJECT/scripts/"
mkdir -p "$PROJECT/hardware-evidence/case"
# shellcheck disable=SC1090
source "$PROJECT/manifests/upstream.lock"
IMAGE='openwrt-qualcommax-ipq807x-xiaomi_ax9000_single_ubi-initramfs-uImage.itb'
MANIFEST='openwrt-qualcommax-ipq807x-xiaomi_ax9000_single_ubi.manifest'
SBOM='openwrt-qualcommax-ipq807x-xiaomi_ax9000_single_ubi.bom.cdx.json'
git -C "$PROJECT" init -q
git -C "$PROJECT" fetch -q "$ROOT_DIR" HEAD
git -C "$PROJECT" reset -q --mixed FETCH_HEAD
PROJECT_COMMIT="$(git -C "$PROJECT" rev-parse HEAD)"
EMPTY_SHA="$(printf '' | sha256sum | awk '{print $1}')"

write_checksums() {
  local directory="$1"
  (cd "$directory" && find . -type f ! -name SHA256SUMS -print | LC_ALL=C sort | while IFS= read -r file; do sha256sum "$file"; done > SHA256SUMS)
}
make_replica() {
  local directory="$1" serial="$2"
  mkdir -p "$directory/EVIDENCE"
  printf firmware > "$directory/$IMAGE"
  printf 'base-files - 1\n' > "$directory/$MANIFEST"
  printf '{"bomFormat":"CycloneDX","serialNumber":"%s","components":[{"type":"library","name":"base-files","version":"1"}]}\n' "$serial" > "$directory/$SBOM"
  for file in config.buildinfo feeds.buildinfo profiles.json version.buildinfo DO-NOT-FLASH.txt; do printf '%s\n' "$file" > "$directory/$file"; done
  cat > "$directory/BUILD-MANIFEST.txt" <<MANIFEST_EOF
project=NexaWrt
flavor=official
project_commit=$PROJECT_COMMIT
layout=$LAYOUT_ID
source_repository=$OPENWRT_REPO
source_tag=$OPENWRT_TAG
source_commit=$OPENWRT_COMMIT
source_date_epoch=1
stage=initramfs-ram-boot-only
real_device_boot_approved=no
image=$IMAGE
package_manifest=$MANIFEST
sbom=$SBOM
rootfs_mtd_offset=$ROOTFS_MTD_OFFSET_HEX
rootfs_mtd_size=$ROOTFS_MTD_SIZE_HEX
MANIFEST_EOF
  {
    printf 'flavor=official\nproject_commit=%s\nproject_tree_state=clean\nsource_commit=%s\nsource_origin=%s\n' "$PROJECT_COMMIT" "$OPENWRT_COMMIT" "$OPENWRT_REPO"
    while read -r name repository commit; do
      [[ -n "$name" && "$name" != \#* ]] || continue
      printf 'feed.%s.commit=%s\nfeed.%s.origin=%s\nfeed.%s.worktree_diff_sha256=%s\n' "$name" "$commit" "$name" "$repository" "$name" "$EMPTY_SHA"
    done < "$PROJECT/manifests/feeds.lock"
  } > "$directory/EVIDENCE/SOURCE-STATE.txt"
  (
    cd "$PROJECT"
    while IFS= read -r -d '' file; do sha256sum "$file"; done < <(scripts/list-build-inputs.sh official)
  ) > "$directory/EVIDENCE/INPUTS.sha256"
  replica_id="${directory##*/}"; replica_id="${replica_id##*-}"
  printf 'schema=1\nflavor=official\nreplica_id=%s\nrun_id=local\nrun_attempt=local\nproject_commit=%s\nsource_commit=%s\n' \
    "$replica_id" "$PROJECT_COMMIT" "$OPENWRT_COMMIT" > "$directory/EVIDENCE/BUILD-IDENTITY.txt"
  printf 'environment %s\n' "$serial" > "$directory/EVIDENCE/BUILD-ENVIRONMENT.txt"
  printf 'build log\n' > "$directory/EVIDENCE/build.log"
  printf 'config\n' > "$directory/EVIDENCE/resolved.config"
  (
    cd "$directory/EVIDENCE"
    find . -type f ! -name EVIDENCE.sha256 -print | LC_ALL=C sort | while IFS= read -r file; do sha256sum "$file"; done
  ) > "$directory/EVIDENCE/EVIDENCE.sha256"
  write_checksums "$directory"
}

make_replica "$PROJECT/a" a
make_replica "$PROJECT/b" b
DIST="$PROJECT/release-staging/case/verified-dist"
"$PROJECT/scripts/compare-reproducible-builds.sh" official "$PROJECT/a" "$PROJECT/b" "$DIST" >/dev/null
output="$TMP/output"
"$PROJECT/scripts/create-hardware-session.sh" "$PROJECT/hardware-evidence/case" "$DIST" > "$output"

session_file="$PROJECT/hardware-evidence/case/SESSION.txt"
candidate_file="$PROJECT/hardware-evidence/case/CANDIDATE.txt"
for file in "$session_file" "$candidate_file"; do
  [[ -f "$file" && ! -L "$file" ]] || fail "$(basename "$file") was not created as a regular file"
  [[ "$(stat -f '%Lp' "$file" 2>/dev/null || stat -c '%a' "$file")" == 600 ]] || fail "$(basename "$file") mode is not 0600"
done
session_id="$(sed -n 's/^session_id=//p' "$session_file")"
[[ "$session_id" =~ ^[0-9a-f]{64}$ ]] || fail 'SESSION.txt does not contain exactly one 64-character lowercase hex ID'
[[ "$(wc -l < "$session_file" | tr -d ' ')" == 1 ]] || fail 'SESSION.txt contains extra lines'
expected_candidate="$($PROJECT/scripts/compare-reproducible-builds.sh --verify-verified-dist "$DIST")"
[[ "$(cat "$candidate_file")" == "$expected_candidate" ]] || fail 'CANDIDATE.txt does not exactly bind verified-dist metadata'
[[ "$(wc -l < "$candidate_file" | tr -d ' ')" == 10 ]] || fail 'CANDIDATE.txt schema is incomplete or has extra fields'
image_sha="$(sha256sum "$DIST/$IMAGE" | awk '{print $1}')"
image_size="$(wc -c < "$DIST/$IMAGE" | tr -d ' ')"
image_size_hex="$(printf '%x' "$image_size")"
comparison_receipt="$(sed -n 's/^comparison_receipt_sha256=//p' "$candidate_file")"
grep -Fq "Expected image SHA-256: $image_sha" "$output" || fail 'image SHA instruction missing'
grep -Fq "U-Boot hexadecimal filesize: $image_size_hex" "$output" || fail 'hex image size instruction missing'
grep -Fq "Comparison receipt SHA-256: $comparison_receipt" "$output" || fail 'comparison receipt instruction missing'
grep -Fq "setenv bootargs \"\${bootargs} nexawrt.session=$session_id\"" "$output" || fail 'volatile session bootargs instruction missing'
grep -Fq 'hash sha256 ${loadaddr} ${filesize} nexawrt_image_sha256' "$output" || fail 'U-Boot image hash instruction missing'
grep -Fq 'printenv nexawrt_image_sha256 nexawrt_image_size_hex nexawrt_session_id ethaddr' "$output" || fail 'UART measurement instruction missing'
grep -Fq 'never run saveenv' "$output" || fail 'saveenv prohibition missing'

first_session="$session_id"
first_candidate_sha="$(sha256sum "$candidate_file" | awk '{print $1}')"
expect_failure 'session recreation in initialized directory' \
  "$PROJECT/scripts/create-hardware-session.sh" "$PROJECT/hardware-evidence/case" "$DIST"
[[ "$(sed -n 's/^session_id=//p' "$session_file")" == "$first_session" ]] || fail 'failed recreation changed SESSION.txt'
[[ "$(sha256sum "$candidate_file" | awk '{print $1}')" == "$first_candidate_sha" ]] || fail 'failed recreation changed CANDIDATE.txt'

mkdir -p "$PROJECT/hardware-evidence/nonempty"
printf 'manual evidence\n' > "$PROJECT/hardware-evidence/nonempty/note.txt"
expect_failure 'non-empty evidence directory' \
  "$PROJECT/scripts/create-hardware-session.sh" "$PROJECT/hardware-evidence/nonempty" "$DIST"
grep -Fxq 'manual evidence' "$PROJECT/hardware-evidence/nonempty/note.txt" || fail 'non-empty directory victim was modified'

mkdir -p "$PROJECT/hardware-evidence/symlink-leaves"
printf 'victim-survives\n' > "$TMP/victim"
ln -s "$TMP/victim" "$PROJECT/hardware-evidence/symlink-leaves/SESSION.txt"
ln -s "$TMP/victim" "$PROJECT/hardware-evidence/symlink-leaves/CANDIDATE.txt"
expect_failure 'pre-existing session metadata symlinks' \
  "$PROJECT/scripts/create-hardware-session.sh" "$PROJECT/hardware-evidence/symlink-leaves" "$DIST"
grep -Fxq victim-survives "$TMP/victim" || fail 'session metadata leaf symlink victim was modified'

mkdir -p "$TMP/outside"
expect_failure 'outside evidence root' "$PROJECT/scripts/create-hardware-session.sh" "$TMP/outside" "$DIST"
ln -s "$TMP/outside" "$PROJECT/hardware-evidence/link"
expect_failure 'symlinked evidence component' "$PROJECT/scripts/create-hardware-session.sh" "$PROJECT/hardware-evidence/link" "$DIST"

LEGACY="$TMP/legacy/verified-dist"
mkdir -p "$LEGACY"
printf firmware > "$LEGACY/$IMAGE"
printf 'flavor=nss\n' > "$LEGACY/BUILD-MANIFEST.txt"
(cd "$LEGACY" && sha256sum "$IMAGE" BUILD-MANIFEST.txt > SHA256SUMS)
mkdir -p "$PROJECT/hardware-evidence/legacy"
expect_failure 'legacy firmware plus flavor fixture' "$PROJECT/scripts/create-hardware-session.sh" "$PROJECT/hardware-evidence/legacy" "$LEGACY"

FORGED="$PROJECT/release-staging/forged/verified-dist"
mkdir -p "$(dirname "$FORGED")"; cp -a "$DIST" "$FORGED"
python3 - "$FORGED/REPRODUCIBILITY.json" <<'PY'
import json, pathlib, sys
path=pathlib.Path(sys.argv[1]); value=json.loads(path.read_text()); value["reproducible"]=False; path.write_text(json.dumps(value,sort_keys=True,separators=(",",":"))+"\n")
PY
write_checksums "$FORGED"
mkdir -p "$PROJECT/hardware-evidence/forged"
expect_failure 'forged reproducibility assertion' "$PROJECT/scripts/create-hardware-session.sh" "$PROJECT/hardware-evidence/forged" "$FORGED"

REPLACED="$PROJECT/release-staging/replaced/verified-dist"
mkdir -p "$(dirname "$REPLACED")"; cp -a "$DIST" "$REPLACED"
printf '\n' >> "$REPLACED/REPRODUCIBILITY/left.SHA256SUMS"
write_checksums "$REPLACED"
mkdir -p "$PROJECT/hardware-evidence/replaced"
expect_failure 'replaced input build receipt' "$PROJECT/scripts/create-hardware-session.sh" "$PROJECT/hardware-evidence/replaced" "$REPLACED"

echo 'hardware session creation requires an empty one-time evidence directory and O_EXCL-binds repository-locked candidate/session metadata: OK'
