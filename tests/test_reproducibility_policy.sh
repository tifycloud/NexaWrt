#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/nexawrt-repro.XXXXXX")"
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "test_reproducibility_policy: $*" >&2; exit 1; }
expect_rejected() {
  local label="$1"; shift
  if "$@" >"$TMP/stdout" 2>"$TMP/stderr"; then fail "$label unexpectedly passed"; fi
}

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
SCRIPT="$PROJECT/scripts/compare-reproducible-builds.sh"
IMAGE='openwrt-qualcommax-ipq807x-xiaomi_ax9000_single_ubi-initramfs-uImage.itb'
MANIFEST='openwrt-qualcommax-ipq807x-xiaomi_ax9000_single_ubi.manifest'
SBOM='openwrt-qualcommax-ipq807x-xiaomi_ax9000_single_ubi.bom.cdx.json'
# shellcheck disable=SC1090
source "$PROJECT/manifests/upstream.lock"
# shellcheck disable=SC1090
source "$PROJECT/manifests/nss.lock"
EMPTY_SHA="$(printf '' | sha256sum | awk '{print $1}')"
NSS_PATCH_SHA="$(sha256sum "$PROJECT/patches/nss/001-pin-codelinaro-source-archives.patch" | awk '{print $1}')"
git -C "$PROJECT" init -q
git -C "$PROJECT" fetch -q "$ROOT_DIR" HEAD
git -C "$PROJECT" reset -q --mixed FETCH_HEAD
PROJECT_COMMIT="$(git -C "$PROJECT" rev-parse HEAD)"
mv "$PROJECT/scripts/build.sh" "$PROJECT/scripts/build.sh.real"
ln -s build.sh.real "$PROJECT/scripts/build.sh"
expect_rejected 'symlinked build input' "$PROJECT/scripts/list-build-inputs.sh" official
rm "$PROJECT/scripts/build.sh"
mv "$PROJECT/scripts/build.sh.real" "$PROJECT/scripts/build.sh"

write_checksums() {
  local directory="$1"
  (cd "$directory" && find . -type f ! -name SHA256SUMS -print | LC_ALL=C sort | while IFS= read -r file; do sha256sum "$file"; done > SHA256SUMS)
}

write_source_state() {
  local directory="$1" flavor="$2" source_repo="$OPENWRT_REPO" source_commit="$OPENWRT_COMMIT"
  if [[ "$flavor" == nss ]]; then source_repo="$NSS_OPENWRT_REPO"; source_commit="$NSS_OPENWRT_COMMIT"; fi
  {
    printf 'flavor=%s\nproject_commit=%s\nproject_tree_state=clean\nsource_commit=%s\nsource_origin=%s\n' \
      "$flavor" "$PROJECT_COMMIT" "$source_commit" "$source_repo"
    while read -r name repository commit; do
      [[ -n "$name" && "$name" != \#* ]] || continue
      printf 'feed.%s.commit=%s\nfeed.%s.origin=%s\nfeed.%s.worktree_diff_sha256=%s\n' \
        "$name" "$commit" "$name" "$repository" "$name" "$EMPTY_SHA"
    done < "$PROJECT/manifests/feeds.lock"
    if [[ "$flavor" == nss ]]; then
      printf 'feed.%s.commit=%s\nfeed.%s.origin=%s\nfeed.%s.worktree_diff_sha256=%s\n' \
        "$NSS_PACKAGES_FEED" "$NSS_PACKAGES_COMMIT" "$NSS_PACKAGES_FEED" "$NSS_PACKAGES_REPO" "$NSS_PACKAGES_FEED" "$NSS_PATCH_SHA"
      printf 'feed.%s.commit=%s\nfeed.%s.origin=%s\nfeed.%s.worktree_diff_sha256=%s\n' \
        "$NSS_SQM_FEED" "$NSS_SQM_COMMIT" "$NSS_SQM_FEED" "$NSS_SQM_REPO" "$NSS_SQM_FEED" "$EMPTY_SHA"
    fi
  } > "$directory/EVIDENCE/SOURCE-STATE.txt"
}

write_inputs() {
  local directory="$1" flavor="$2" file
  (
    cd "$PROJECT"
    while IFS= read -r -d '' file; do sha256sum "$file"; done < <(scripts/list-build-inputs.sh "$flavor")
  ) > "$directory/EVIDENCE/INPUTS.sha256"
}

make_replica() {
  local directory="$1" serial="$2" timestamp="$3" flavor="${4:-official}"
  rm -rf "$directory"
  mkdir -p "$directory/EVIDENCE"
  printf firmware > "$directory/$IMAGE"
  printf 'base-files - 1\n' > "$directory/$MANIFEST"
  printf '{"bomFormat":"CycloneDX","serialNumber":"%s","metadata":{"timestamp":"%s"},"components":[{"type":"library","name":"base-files","version":"1"}]}\n' "$serial" "$timestamp" > "$directory/$SBOM"
  for file in config.buildinfo feeds.buildinfo profiles.json version.buildinfo DO-NOT-FLASH.txt; do printf '%s\n' "$file" > "$directory/$file"; done
  if [[ "$flavor" == official ]]; then
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
  else
    cat > "$directory/BUILD-MANIFEST.txt" <<MANIFEST_EOF
project=NexaWrt
flavor=nss
project_commit=$PROJECT_COMMIT
source_repository=$NSS_OPENWRT_REPO
source_branch=$NSS_OPENWRT_BRANCH
source_commit=$NSS_OPENWRT_COMMIT
source_date_epoch=1
nss_packages_feed_repository=$NSS_PACKAGES_REPO
nss_packages_feed_commit=$NSS_PACKAGES_COMMIT
nss_sqm_feed_repository=$NSS_SQM_REPO
nss_sqm_feed_commit=$NSS_SQM_COMMIT
stage=initramfs-ram-boot-only
real_device_boot_approved=no
image=$IMAGE
package_manifest=$MANIFEST
sbom=$SBOM
MANIFEST_EOF
    mkdir -p "$directory/LICENSES/nss-firmware"
    printf 'third party\n' > "$directory/THIRD_PARTY_NOTICES.md"
    printf 'license\n' > "$directory/LICENSES/nss-firmware/LICENSE.md"
  fi
  write_source_state "$directory" "$flavor"
  write_inputs "$directory" "$flavor"
  replica_id="${directory##*/}"; replica_id="${replica_id##*-}"
  identity_source_commit="$OPENWRT_COMMIT"; [[ "$flavor" == nss ]] && identity_source_commit="$NSS_OPENWRT_COMMIT"
  printf 'schema=1\nflavor=%s\nreplica_id=%s\nrun_id=local\nrun_attempt=local\nproject_commit=%s\nsource_commit=%s\n' \
    "$flavor" "$replica_id" "$PROJECT_COMMIT" "$identity_source_commit" > "$directory/EVIDENCE/BUILD-IDENTITY.txt"
  printf '%s\n' "$serial" > "$directory/EVIDENCE/BUILD-ENVIRONMENT.txt"
  printf 'build log\n' > "$directory/EVIDENCE/build.log"
  printf 'config\n' > "$directory/EVIDENCE/resolved.config"
  (
    cd "$directory/EVIDENCE"
    find . -type f ! -name EVIDENCE.sha256 -print | LC_ALL=C sort | while IFS= read -r file; do sha256sum "$file"; done
  ) > "$directory/EVIDENCE/EVIDENCE.sha256"
  write_checksums "$directory"
}

make_replica "$PROJECT/a" urn:uuid:a 2026-01-01T00:00:00Z
make_replica "$PROJECT/b" urn:uuid:b 2026-01-02T00:00:00Z
OUT="$PROJECT/release-staging/success/verified-dist"
"$SCRIPT" official "$PROJECT/a" "$PROJECT/b" "$OUT" >/dev/null
metadata="$($SCRIPT --verify-verified-dist "$OUT")"
grep -Fxq 'schema=1' <<<"$metadata" || fail 'candidate metadata schema missing'
grep -Eq '^comparison_receipt_sha256=[0-9a-f]{64}$' <<<"$metadata" || fail 'comparison receipt missing'
python3 - "$OUT/REPRODUCIBILITY.json" <<'PY'
import json, pathlib, sys
value=json.loads(pathlib.Path(sys.argv[1]).read_text())
assert value["schema"] == 4 and value["reproducible"] is True
assert [item["slot"] for item in value["input_builds"]] == ["left", "right"]
assert [item["replica_id"] for item in value["input_builds"]] == ["a", "b"]
assert [item["producer_id"] for item in value["input_builds"]] == ["local-unattested:a", "local-unattested:b"]
assert all(item["identity_filename"].endswith(".BUILD-IDENTITY.txt") for item in value["input_builds"])
assert value["firmware"]["size"] == len(b"firmware")
PY

expect_rejected 'GitHub comparison without platform producers' env GITHUB_ACTIONS=true \
  GITHUB_RUN_ID=local GITHUB_RUN_ATTEMPT=local "$SCRIPT" official "$PROJECT/a" "$PROJECT/b" \
  "$PROJECT/release-staging/no-platform-producer/verified-dist"
mkdir -p "$PROJECT/release-staging/test-provenance" "$TMP/bin"
write_descriptor() {
  local replica="$1" artifact_id="$2" artifact_name="release-local-local-official-$1" receipt="$PROJECT/$1/SHA256SUMS"
  /usr/bin/python3 - "$PROJECT/release-staging/test-provenance/$replica.descriptor.json" "$receipt" \
    "$replica" "$artifact_id" "$artifact_name" <<'PY'
import hashlib, json, pathlib, sys
path, receipt, replica, artifact_id, artifact_name = sys.argv[1:]
value = {
    "artifact_id": artifact_id,
    "artifact_name": artifact_name,
    "flavor": "official",
    "receipt_filename": "SHA256SUMS",
    "receipt_sha256": hashlib.sha256(pathlib.Path(receipt).read_bytes()).hexdigest(),
    "replica_id": replica,
    "repository": "tifycloud/NexaWrt",
    "run_attempt": "local",
    "run_id": "local",
    "schema": 1,
    "workflow": "tifycloud/NexaWrt/.github/workflows/release.yml",
}
pathlib.Path(path).write_text(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n")
PY
  printf 'descriptor_sha256=%s\n' "$(sha256sum "$PROJECT/release-staging/test-provenance/$replica.descriptor.json" | awk '{print $1}')" \
    > "$PROJECT/release-staging/test-provenance/$replica.bundle.json"
}
write_descriptor a 101
write_descriptor b 102
cat > "$TMP/bin/mock-gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == attestation && "$2" == verify ]]
subject="$3"; shift 3
bundle=""
while (($#)); do
  case "$1" in
    --repo|--signer-workflow) shift 2 ;;
    --bundle) bundle="$2"; shift 2 ;;
    *) exit 1 ;;
  esac
done
[[ -n "$bundle" ]]
expected="$(awk -F= '$1 == "descriptor_sha256" {print $2}' "$bundle")"
actual="$(sha256sum "$subject" | awk '{print $1}')"
[[ "$actual" == "$expected" ]]
GH
chmod +x "$TMP/bin/mock-gh"
VERIFIER="$TMP/bin/mock-gh"
VERIFIER_SHA="$(sha256sum "$VERIFIER" | awk '{print $1}')"
DESC_A="$PROJECT/release-staging/test-provenance/a.descriptor.json"
DESC_B="$PROJECT/release-staging/test-provenance/b.descriptor.json"
BUNDLE_A="$PROJECT/release-staging/test-provenance/a.bundle.json"
BUNDLE_B="$PROJECT/release-staging/test-provenance/b.bundle.json"
expect_rejected 'PATH-only mock verifier' env PATH="$TMP/bin:$PATH" GITHUB_ACTIONS=true GITHUB_RUN_ID=local GITHUB_RUN_ATTEMPT=local \
  NEXAWRT_LEFT_ARTIFACT_ID=101 NEXAWRT_RIGHT_ARTIFACT_ID=102 \
  NEXAWRT_LEFT_ARTIFACT_NAME=release-local-local-official-a NEXAWRT_RIGHT_ARTIFACT_NAME=release-local-local-official-b \
  NEXAWRT_LEFT_PRODUCER_DESCRIPTOR="$DESC_A" NEXAWRT_RIGHT_PRODUCER_DESCRIPTOR="$DESC_B" \
  NEXAWRT_LEFT_PROVENANCE_BUNDLE="$BUNDLE_A" NEXAWRT_RIGHT_PROVENANCE_BUNDLE="$BUNDLE_B" \
  "$SCRIPT" official "$PROJECT/a" "$PROJECT/b" "$PROJECT/release-staging/path-only/verified-dist"
expect_rejected 'missing verifier hash' env GITHUB_ACTIONS=true GITHUB_RUN_ID=local GITHUB_RUN_ATTEMPT=local \
  NEXAWRT_ATTESTATION_VERIFIER="$VERIFIER" \
  NEXAWRT_LEFT_ARTIFACT_ID=101 NEXAWRT_RIGHT_ARTIFACT_ID=102 \
  NEXAWRT_LEFT_ARTIFACT_NAME=release-local-local-official-a NEXAWRT_RIGHT_ARTIFACT_NAME=release-local-local-official-b \
  NEXAWRT_LEFT_PRODUCER_DESCRIPTOR="$DESC_A" NEXAWRT_RIGHT_PRODUCER_DESCRIPTOR="$DESC_B" \
  NEXAWRT_LEFT_PROVENANCE_BUNDLE="$BUNDLE_A" NEXAWRT_RIGHT_PROVENANCE_BUNDLE="$BUNDLE_B" \
  "$SCRIPT" official "$PROJECT/a" "$PROJECT/b" "$PROJECT/release-staging/missing-verifier-hash/verified-dist"
expect_rejected 'wrong verifier hash' env GITHUB_ACTIONS=true GITHUB_RUN_ID=local GITHUB_RUN_ATTEMPT=local \
  NEXAWRT_ATTESTATION_VERIFIER="$VERIFIER" NEXAWRT_ATTESTATION_VERIFIER_SHA256="$(printf '%064d' 0)" \
  NEXAWRT_LEFT_ARTIFACT_ID=101 NEXAWRT_RIGHT_ARTIFACT_ID=102 \
  NEXAWRT_LEFT_ARTIFACT_NAME=release-local-local-official-a NEXAWRT_RIGHT_ARTIFACT_NAME=release-local-local-official-b \
  NEXAWRT_LEFT_PRODUCER_DESCRIPTOR="$DESC_A" NEXAWRT_RIGHT_PRODUCER_DESCRIPTOR="$DESC_B" \
  NEXAWRT_LEFT_PROVENANCE_BUNDLE="$BUNDLE_A" NEXAWRT_RIGHT_PROVENANCE_BUNDLE="$BUNDLE_B" \
  "$SCRIPT" official "$PROJECT/a" "$PROJECT/b" "$PROJECT/release-staging/wrong-verifier-hash/verified-dist"
cp "$DESC_A" "$PROJECT/release-staging/test-provenance/relabel.descriptor.json"
/usr/bin/python3 - "$PROJECT/release-staging/test-provenance/relabel.descriptor.json" <<'PY'
import json, pathlib, sys
path=pathlib.Path(sys.argv[1]); value=json.loads(path.read_text()); value["artifact_id"]="999"
path.write_text(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n")
PY
expect_rejected 'artifact id relabel' env GITHUB_ACTIONS=true GITHUB_RUN_ID=local GITHUB_RUN_ATTEMPT=local \
  NEXAWRT_ATTESTATION_VERIFIER="$VERIFIER" NEXAWRT_ATTESTATION_VERIFIER_SHA256="$VERIFIER_SHA" \
  NEXAWRT_LEFT_ARTIFACT_ID=101 NEXAWRT_RIGHT_ARTIFACT_ID=102 \
  NEXAWRT_LEFT_ARTIFACT_NAME=release-local-local-official-a NEXAWRT_RIGHT_ARTIFACT_NAME=release-local-local-official-b \
  NEXAWRT_LEFT_PRODUCER_DESCRIPTOR="$PROJECT/release-staging/test-provenance/relabel.descriptor.json" NEXAWRT_RIGHT_PRODUCER_DESCRIPTOR="$DESC_B" \
  NEXAWRT_LEFT_PROVENANCE_BUNDLE="$BUNDLE_A" NEXAWRT_RIGHT_PROVENANCE_BUNDLE="$BUNDLE_B" \
  "$SCRIPT" official "$PROJECT/a" "$PROJECT/b" "$PROJECT/release-staging/relabel/verified-dist"
PLATFORM_OUT="$PROJECT/release-staging/platform/verified-dist"
env GITHUB_ACTIONS=true GITHUB_RUN_ID=local GITHUB_RUN_ATTEMPT=local \
  NEXAWRT_ATTESTATION_VERIFIER="$VERIFIER" NEXAWRT_ATTESTATION_VERIFIER_SHA256="$VERIFIER_SHA" \
  NEXAWRT_LEFT_ARTIFACT_ID=101 NEXAWRT_RIGHT_ARTIFACT_ID=102 \
  NEXAWRT_LEFT_ARTIFACT_NAME=release-local-local-official-a NEXAWRT_RIGHT_ARTIFACT_NAME=release-local-local-official-b \
  NEXAWRT_LEFT_PRODUCER_DESCRIPTOR="$DESC_A" NEXAWRT_RIGHT_PRODUCER_DESCRIPTOR="$DESC_B" \
  NEXAWRT_LEFT_PROVENANCE_BUNDLE="$BUNDLE_A" NEXAWRT_RIGHT_PROVENANCE_BUNDLE="$BUNDLE_B" \
  "$SCRIPT" official "$PROJECT/a" "$PROJECT/b" "$PLATFORM_OUT" >/dev/null
/usr/bin/python3 - "$PLATFORM_OUT/REPRODUCIBILITY.json" <<'PY'
import json, pathlib, sys
value=json.loads(pathlib.Path(sys.argv[1]).read_text())
assert value["schema"] == 4
assert [item["artifact_id"] for item in value["input_builds"]] == ["101", "102"]
assert all(item["producer_descriptor_filename"].endswith(".producer-descriptor.json") for item in value["input_builds"])
assert all(len(item["producer_descriptor_sha256"]) == 64 for item in value["input_builds"])
PY
[[ -s "$PLATFORM_OUT/REPRODUCIBILITY/left.producer-descriptor.json" ]] || fail 'left producer descriptor missing from verified-dist'
[[ -s "$PLATFORM_OUT/REPRODUCIBILITY/right.producer-descriptor.json" ]] || fail 'right producer descriptor missing from verified-dist'
[[ -s "$PLATFORM_OUT/REPRODUCIBILITY/left.provenance.bundle.json" ]] || fail 'left provenance bundle missing from verified-dist'
[[ -s "$PLATFORM_OUT/REPRODUCIBILITY/right.provenance.bundle.json" ]] || fail 'right provenance bundle missing from verified-dist'
env GITHUB_ACTIONS=true GITHUB_RUN_ID=local GITHUB_RUN_ATTEMPT=local \
  NEXAWRT_ATTESTATION_VERIFIER="$VERIFIER" NEXAWRT_ATTESTATION_VERIFIER_SHA256="$VERIFIER_SHA" \
  "$SCRIPT" --verify-verified-dist "$PLATFORM_OUT" >/dev/null

rm -rf "$PROJECT/b"; cp -a "$PROJECT/a" "$PROJECT/b"
expect_rejected 'duplicated build receipt' "$SCRIPT" official "$PROJECT/a" "$PROJECT/b" "$PROJECT/release-staging/duplicate-build/verified-dist"

make_replica "$PROJECT/b" urn:uuid:b 2026-01-02T00:00:00Z
awk '$2 != "scripts/build.sh"' "$PROJECT/b/EVIDENCE/INPUTS.sha256" > "$PROJECT/b/EVIDENCE/INPUTS.sha256.new"
mv "$PROJECT/b/EVIDENCE/INPUTS.sha256.new" "$PROJECT/b/EVIDENCE/INPUTS.sha256"
write_checksums "$PROJECT/b"
expect_rejected 'missing full build input' "$SCRIPT" official "$PROJECT/a" "$PROJECT/b" "$PROJECT/release-staging/missing-input/verified-dist"

make_replica "$PROJECT/b" urn:uuid:b 2026-01-02T00:00:00Z
awk '$2 == "configs/ax9000-single-ubi.config" {$1=sprintf("%064d",0)} {print $1 "  " $2}' \
  "$PROJECT/b/EVIDENCE/INPUTS.sha256" > "$PROJECT/b/EVIDENCE/INPUTS.sha256.new"
mv "$PROJECT/b/EVIDENCE/INPUTS.sha256.new" "$PROJECT/b/EVIDENCE/INPUTS.sha256"
write_checksums "$PROJECT/b"
expect_rejected 'modified full build input digest' "$SCRIPT" official "$PROJECT/a" "$PROJECT/b" "$PROJECT/release-staging/bad-input-digest/verified-dist"

make_replica "$PROJECT/b" urn:uuid:b 2026-01-02T00:00:00Z
printf '%064d  scripts/not-a-build-input.sh\n' 0 >> "$PROJECT/b/EVIDENCE/INPUTS.sha256"
write_checksums "$PROJECT/b"
expect_rejected 'extra build input' "$SCRIPT" official "$PROJECT/a" "$PROJECT/b" "$PROJECT/release-staging/extra-input/verified-dist"

make_replica "$PROJECT/b" urn:uuid:b 2026-01-02T00:00:00Z
awk '$2 != "./BUILD-ENVIRONMENT.txt"' "$PROJECT/b/EVIDENCE/EVIDENCE.sha256" > "$PROJECT/b/EVIDENCE/EVIDENCE.sha256.new"
mv "$PROJECT/b/EVIDENCE/EVIDENCE.sha256.new" "$PROJECT/b/EVIDENCE/EVIDENCE.sha256"
write_checksums "$PROJECT/b"
expect_rejected 'incomplete evidence receipt' "$SCRIPT" official "$PROJECT/a" "$PROJECT/b" "$PROJECT/release-staging/incomplete-evidence/verified-dist"

printf changed >> "$PROJECT/b/$IMAGE"; write_checksums "$PROJECT/b"
expect_rejected 'firmware mismatch' "$SCRIPT" official "$PROJECT/a" "$PROJECT/b" "$PROJECT/release-staging/fail/verified-dist"
make_replica "$PROJECT/b" urn:uuid:b 2026-01-02T00:00:00Z
python3 - "$PROJECT/b/$SBOM" <<'PY'
import json, pathlib, sys
path=pathlib.Path(sys.argv[1]); value=json.loads(path.read_text()); value["components"][0]["version"]="2"; path.write_text(json.dumps(value)+"\n")
PY
write_checksums "$PROJECT/b"
expect_rejected 'SBOM mismatch' "$SCRIPT" official "$PROJECT/a" "$PROJECT/b" "$PROJECT/release-staging/fail-sbom/verified-dist"

make_replica "$PROJECT/b" urn:uuid:b 2026-01-02T00:00:00Z
sed -i.bak "s/source_commit=$OPENWRT_COMMIT/source_commit=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/" "$PROJECT/b/BUILD-MANIFEST.txt"; rm "$PROJECT/b/BUILD-MANIFEST.txt.bak"
write_checksums "$PROJECT/b"
expect_rejected 'wrong source lock' "$SCRIPT" official "$PROJECT/a" "$PROJECT/b" "$PROJECT/release-staging/wrong-source/verified-dist"

make_replica "$PROJECT/b" urn:uuid:b 2026-01-02T00:00:00Z
sed -i.bak 's/project_tree_state=clean/project_tree_state=dirty/' "$PROJECT/b/EVIDENCE/SOURCE-STATE.txt"; rm "$PROJECT/b/EVIDENCE/SOURCE-STATE.txt.bak"
write_checksums "$PROJECT/b"
expect_rejected 'dirty project tree' "$SCRIPT" official "$PROJECT/a" "$PROJECT/b" "$PROJECT/release-staging/dirty-tree/verified-dist"

make_replica "$PROJECT/b" urn:uuid:b 2026-01-02T00:00:00Z
sed -i.bak "s/project_commit=$PROJECT_COMMIT/project_commit=0000000000000000000000000000000000000000/" "$PROJECT/b/BUILD-MANIFEST.txt"; rm "$PROJECT/b/BUILD-MANIFEST.txt.bak"
sed -i.bak "s/project_commit=$PROJECT_COMMIT/project_commit=0000000000000000000000000000000000000000/" "$PROJECT/b/EVIDENCE/SOURCE-STATE.txt"; rm "$PROJECT/b/EVIDENCE/SOURCE-STATE.txt.bak"
write_checksums "$PROJECT/b"
expect_rejected 'stale project commit' "$SCRIPT" official "$PROJECT/a" "$PROJECT/b" "$PROJECT/release-staging/stale-project/verified-dist"

make_replica "$PROJECT/nss-a" urn:uuid:a 2026-01-01T00:00:00Z nss
make_replica "$PROJECT/nss-b" urn:uuid:b 2026-01-02T00:00:00Z nss
sed -i.bak "s/feed.$NSS_PACKAGES_FEED.worktree_diff_sha256=$NSS_PATCH_SHA/feed.$NSS_PACKAGES_FEED.worktree_diff_sha256=$EMPTY_SHA/" "$PROJECT/nss-b/EVIDENCE/SOURCE-STATE.txt"; rm "$PROJECT/nss-b/EVIDENCE/SOURCE-STATE.txt.bak"
write_checksums "$PROJECT/nss-b"
expect_rejected 'wrong feed patch lock' "$SCRIPT" nss "$PROJECT/nss-a" "$PROJECT/nss-b" "$PROJECT/release-staging/wrong-feed-patch/verified-dist"
make_replica "$PROJECT/nss-b" urn:uuid:b 2026-01-02T00:00:00Z nss
sed -i.bak "s/feed.$NSS_PACKAGES_FEED.commit=$NSS_PACKAGES_COMMIT/feed.$NSS_PACKAGES_FEED.commit=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/" "$PROJECT/nss-b/EVIDENCE/SOURCE-STATE.txt"; rm "$PROJECT/nss-b/EVIDENCE/SOURCE-STATE.txt.bak"
write_checksums "$PROJECT/nss-b"
expect_rejected 'wrong feed commit lock' "$SCRIPT" nss "$PROJECT/nss-a" "$PROJECT/nss-b" "$PROJECT/release-staging/wrong-feed-commit/verified-dist"
make_replica "$PROJECT/nss-b" urn:uuid:b 2026-01-02T00:00:00Z nss
"$SCRIPT" nss "$PROJECT/nss-a" "$PROJECT/nss-b" "$PROJECT/release-staging/nss/verified-dist" >/dev/null

cp -a "$OUT" "$PROJECT/release-staging/missing-repro-verified-dist"
expect_rejected 'misnamed verified dist' "$SCRIPT" --verify-verified-dist "$PROJECT/release-staging/missing-repro-verified-dist"

mutate_output() {
  local name="$1" python_code="$2"
  local target="$PROJECT/release-staging/$name/verified-dist"
  rm -rf "$PROJECT/release-staging/$name"; mkdir -p "$PROJECT/release-staging/$name"; cp -a "$OUT" "$target"
  python3 - "$target/REPRODUCIBILITY.json" "$python_code" <<'PY'
import json, pathlib, sys
path=pathlib.Path(sys.argv[1]); value=json.loads(path.read_text()); exec(sys.argv[2]); path.write_text(json.dumps(value,sort_keys=True,separators=(",",":"))+"\n")
PY
  write_checksums "$target"
  expect_rejected "$name" "$SCRIPT" --verify-verified-dist "$target"
}
mutate_output forged-reproducible 'value["reproducible"]=False'
mutate_output wrong-firmware-hash 'value["firmware"]["sha256"]="0"*64'
mutate_output wrong-firmware-size 'value["firmware"]["size"]+=1'
mutate_output replaced-receipt-digest 'value["input_builds"][0]["receipt_sha256"]="0"*64'
mutate_output replaced-comparison-receipt 'value["comparison_receipt_sha256"]="0"*64'

rm "$OUT/REPRODUCIBILITY.json"; write_checksums "$OUT"
expect_rejected 'missing reproducibility metadata' "$SCRIPT" --verify-verified-dist "$OUT"

echo 'reproducibility schema-4 signed producer descriptors, dual-build receipts, repository locks, exact artifacts, and fail-closed verified-dist policy: OK'
