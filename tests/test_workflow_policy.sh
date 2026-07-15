#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; BUILD="$ROOT_DIR/.github/workflows/build.yml"; RELEASE="$ROOT_DIR/.github/workflows/release.yml"
for workflow in "$BUILD" "$RELEASE"; do
  while read -r use; do
    [[ "$use" =~ @[0-9a-f]{40}$ ]] || { echo "workflow action is not pinned to a full commit: $use" >&2; exit 1; }
  done < <(sed -nE 's/^[[:space:]]*uses:[[:space:]]*([^ #]+).*/\1/p' "$workflow")
done
grep -Fq 'persist-credentials: false' "$BUILD"
grep -Fq 'persist-credentials: false' "$RELEASE"
grep -Fq 'shellcheck -S warning' "$BUILD"
grep -Fq 'shellcheck -S warning' "$RELEASE"
grep -Fq 'merge_group:' "$BUILD"
grep -Fq 'branches: [main]' "$BUILD"
grep -Fq 'permissions: {}' "$RELEASE"
grep -Fq 'cancel-in-progress: false' "$RELEASE"
tag_entry_count="$(awk '/^    tags:/{tags=1; next} tags && /^      - /{count++; next} tags{exit} END{print count+0}' "$RELEASE")"
[[ "$tag_entry_count" == 2 ]] || { echo 'release workflow exposes an unexpected tag trigger' >&2; exit 1; }
[[ "$(grep -Ec "^[[:space:]]+- 'ram-test(-nss)?-v\*'" "$RELEASE")" == 2 ]] || { echo 'release workflow does not expose exactly the official and NSS tag families' >&2; exit 1; }
grep -Fq -- "- 'ram-test-v*'" "$RELEASE"
grep -Fq -- "- 'ram-test-nss-v*'" "$RELEASE"
grep -Fq '^ram-test-v[0-9][0-9A-Za-z._-]*$' "$RELEASE"
grep -Fq '^ram-test-nss-v[0-9][0-9A-Za-z._-]*$' "$RELEASE"
official_tag_pattern='^ram-test-v[0-9][0-9A-Za-z._-]*$'
nss_tag_pattern='^ram-test-nss-v[0-9][0-9A-Za-z._-]*$'
[[ ram-test-v1.2.3 =~ $official_tag_pattern ]]
[[ ram-test-nss-v1.2.3-rc1 =~ $nss_tag_pattern ]]
for untrusted_tag in ram-test-v ram-test-nss-v ram-test-debug-v1 ram-test-v1/other ram-test-nss-v1/other; do
  ! [[ "$untrusted_tag" =~ $official_tag_pattern || "$untrusted_tag" =~ $nss_tag_pattern ]] || { echo "untrusted tag matches a release flavor: $untrusted_tag" >&2; exit 1; }
done
grep -Fq 'Untrusted release tag name' "$RELEASE"
grep -Fq 'flavor=official' "$RELEASE"
grep -Fq 'flavor=nss' "$RELEASE"
grep -Fq 'work_basename=openwrt' "$RELEASE"
grep -Fq 'work_basename=openwrt-nss' "$RELEASE"
grep -Fq 'staging_basename=dist' "$RELEASE"
grep -Fq 'staging_basename=dist-nss' "$RELEASE"
grep -Fq 'flavor: ${{ steps.release_identity.outputs.flavor }}' "$RELEASE"
grep -Fq 'NEXAWRT_FLAVOR: ${{ needs.preflight.outputs.flavor }}' "$RELEASE"
grep -Fq 'NEXAWRT_BUILD_REPLICA: ${{ matrix.replica }}' "$RELEASE"
! grep -Fq 'NEXAWRT_FLAVOR: official' "$RELEASE"
grep -Fq 'replica: [a, b]' "$RELEASE"
grep -Fq 'WORK_DIR: .work/${{ needs.preflight.outputs.work_basename }}-${{ matrix.replica }}' "$RELEASE"
grep -Fq 'DIST_DIR_OVERRIDE: ${{ github.workspace }}/release-staging/replica-${{ needs.preflight.outputs.flavor }}-${{ matrix.replica }}/${{ needs.preflight.outputs.staging_basename }}' "$RELEASE"
grep -Fq 'DIST_NSS_DIR_OVERRIDE: ${{ github.workspace }}/release-staging/replica-${{ needs.preflight.outputs.flavor }}-${{ matrix.replica }}/${{ needs.preflight.outputs.staging_basename }}' "$RELEASE"
! grep -Fq 'uses: actions/cache@' "$RELEASE"
grep -Fq 'release-${{ github.run_id }}-${{ github.run_attempt }}-${{ needs.preflight.outputs.flavor }}-${{ matrix.replica }}' "$RELEASE"
grep -Fq 'needs: [preflight, build]' "$RELEASE"
grep -Fq 'needs: [preflight, compare]' "$RELEASE"
grep -Fq 'compare-reproducible-builds.sh "$RELEASE_FLAVOR"' "$RELEASE"
! grep -Fq 'compare-reproducible-builds.sh official' "$RELEASE"
grep -Fq 'release-staging/replicas/"$RELEASE_FLAVOR"/a' "$RELEASE"
grep -Fq 'release-staging/replicas/"$RELEASE_FLAVOR"/b' "$RELEASE"
grep -Fq 'verified-release-${{ github.run_id }}-${{ github.run_attempt }}-${{ needs.preflight.outputs.flavor }}' "$RELEASE"
grep -Fq 'release-staging/verified-dist' "$RELEASE"
grep -Fq 'environment: ram-test-release' "$RELEASE"
grep -Fq 'grep -Fxq "flavor=$RELEASE_FLAVOR"' "$RELEASE"
grep -Fq "grep -Fq 'initramfs RAM-boot candidate only.'" "$RELEASE"
grep -Fq 'git cat-file -t "refs/tags/$GITHUB_REF_NAME"' "$RELEASE"
grep -Fq 'git/ref/tags/$GITHUB_REF_NAME' "$RELEASE"
grep -Fq 'test "$remote_sha" = "$GITHUB_SHA"' "$RELEASE"
grep -Fq 'gh release create "$GITHUB_REF_NAME" --verify-tag --draft --prerelease' "$RELEASE"
grep -Fq 'attestations: write' "$RELEASE"
grep -Fq 'actions/attest-build-provenance@96278af6caaf10aea03fd8d33a09a777ca52d62f' "$RELEASE"
[[ "$(grep -Fc 'actions/attest-build-provenance@96278af6caaf10aea03fd8d33a09a777ca52d62f' "$RELEASE")" == 5 ]] || {
  echo 'release workflow must attest each producer descriptor plus the four publish subjects' >&2; exit 1
}
grep -Fq 'subject-path: release-staging/replica-provenance-${{ matrix.replica }}/producer-descriptor.json' "$RELEASE"
grep -Fq '"repository": "tifycloud/NexaWrt"' "$RELEASE"
grep -Fq '"workflow": "tifycloud/NexaWrt/.github/workflows/release.yml"' "$RELEASE"
for field in schema repository workflow run_id run_attempt flavor replica_id artifact_id artifact_name receipt_filename receipt_sha256; do
  grep -Fq "\"$field\"" "$RELEASE" || { echo "producer descriptor field missing: $field" >&2; exit 1; }
done
grep -Fq 'replica-provenance-${{ github.run_id }}-${{ github.run_attempt }}-${{ needs.preflight.outputs.flavor }}-${{ matrix.replica }}' "$RELEASE"
grep -Fq 'producer-descriptor.provenance.bundle.json' "$RELEASE"
grep -Fq 'attestations: read' "$RELEASE"
grep -Fq '/usr/bin/gh api "repos/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID/artifacts?per_page=100"' "$RELEASE"
[[ "$(grep -Fc 'NEXAWRT_ATTESTATION_VERIFIER=/usr/bin/gh' "$RELEASE")" == 2 ]] || { echo 'compare and publish do not pin /usr/bin/gh' >&2; exit 1; }
[[ "$(grep -Fc 'NEXAWRT_ATTESTATION_VERIFIER_SHA256=' "$RELEASE")" == 2 ]] || { echo 'compare and publish do not bind verifier SHA256' >&2; exit 1; }
grep -Fq 'NEXAWRT_LEFT_ARTIFACT_ID: ${{ steps.producer_identity.outputs.left_artifact_id }}' "$RELEASE"
grep -Fq 'NEXAWRT_RIGHT_ARTIFACT_ID: ${{ steps.producer_identity.outputs.right_artifact_id }}' "$RELEASE"
grep -Fq 'NEXAWRT_LEFT_ARTIFACT_NAME: ${{ steps.producer_identity.outputs.left_artifact_name }}' "$RELEASE"
grep -Fq 'NEXAWRT_RIGHT_ARTIFACT_NAME: ${{ steps.producer_identity.outputs.right_artifact_name }}' "$RELEASE"
grep -Fq 'NEXAWRT_LEFT_PRODUCER_DESCRIPTOR: release-staging/provenance/${{ needs.preflight.outputs.flavor }}/a/producer-descriptor.json' "$RELEASE"
grep -Fq 'NEXAWRT_RIGHT_PRODUCER_DESCRIPTOR: release-staging/provenance/${{ needs.preflight.outputs.flavor }}/b/producer-descriptor.json' "$RELEASE"
grep -Fq 'NEXAWRT_LEFT_PROVENANCE_BUNDLE: release-staging/provenance/${{ needs.preflight.outputs.flavor }}/a/producer-descriptor.provenance.bundle.json' "$RELEASE"
grep -Fq 'NEXAWRT_RIGHT_PROVENANCE_BUNDLE: release-staging/provenance/${{ needs.preflight.outputs.flavor }}/b/producer-descriptor.provenance.bundle.json' "$RELEASE"

# verified-dist is an immutable input to publish: verify it, archive it externally,
# verify the unpacked archive, and never append or copy release products into it.
[[ "$(grep -Fc './scripts/compare-reproducible-builds.sh --verify-verified-dist release-staging/verified-dist' "$RELEASE")" == 2 ]] || {
  echo 'downloaded verified-dist is not strictly verified both before packaging and immediately before release' >&2; exit 1
}
[[ "$(grep -Fc './scripts/compare-reproducible-builds.sh --verify-verified-dist "$extract_dir/verified-dist"' "$RELEASE")" == 1 ]] || {
  echo 'unpacked verified-dist is not strictly re-verified exactly once' >&2; exit 1
}
! grep -Eq '>>[^#]*verified-dist/SHA256SUMS' "$RELEASE" || { echo 'release workflow appends to verified-dist/SHA256SUMS' >&2; exit 1; }
if python3 - "$RELEASE" <<'PY'
import pathlib
import shlex
import sys

for line_number, raw in enumerate(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines(), 1):
    line = raw.strip()
    if not line.startswith("cp "):
        continue
    try:
        destination = shlex.split(line)[-1].rstrip("/")
    except (ValueError, IndexError):
        continue
    if "verified-dist" in pathlib.PurePosixPath(destination).parts:
        print(f"copy destination enters verified-dist on line {line_number}: {raw}", file=sys.stderr)
        raise SystemExit(0)
raise SystemExit(1)
PY
then
  echo 'release workflow copies a file into verified-dist' >&2; exit 1
fi
grep -Fq 'mkdir release-staging/publish' "$RELEASE"
grep -Fq -- '-C release-staging -cf - verified-dist | gzip -9n > "release-staging/publish/$archive_basename"' "$RELEASE"
grep -Fq 'sha256sum "$archive_basename" > "$archive_basename.sha256"' "$RELEASE"
grep -Fq 'sha256sum -c "$archive_basename.sha256"' "$RELEASE"
grep -Fq 'tar -xzf "release-staging/publish/$archive_basename" -C "$extract_dir"' "$RELEASE"
grep -Fq 'subject-path: release-staging/publish/NexaWrt-AX9000-${{ needs.preflight.outputs.flavor }}-verified-dist.tar.gz' "$RELEASE"
[[ "$(grep -Ec "cp .*release-staging/publish/[a-z]+\.provenance\.bundle\.json$" "$RELEASE")" == 4 ]] || {
  echo 'all provenance bundles are not copied into publish' >&2; exit 1
}
[[ "$(grep -Fc 'find release-staging/publish -maxdepth 1 -type f' "$RELEASE")" == 2 ]] || {
  echo 'release upload and asset verification do not both enumerate the complete publish directory' >&2; exit 1
}
! grep -Eq 'gh release upload .*verified-dist|find release-staging/verified-dist .*-(print0|exec)' "$RELEASE" || {
  echo 'release assets are uploaded directly from verified-dist instead of publish' >&2; exit 1
}
grep -Fq -- '- name: Checkout verification policy' "$RELEASE"
source_verify_first_line="$(awk 'index($0, "./scripts/compare-reproducible-builds.sh --verify-verified-dist release-staging/verified-dist") { print NR; exit }' "$RELEASE")"
source_verify_last_line="$(awk 'index($0, "./scripts/compare-reproducible-builds.sh --verify-verified-dist release-staging/verified-dist") { line=NR } END { print line }' "$RELEASE")"
publish_line="$(awk '$0 == "  publish:" { print NR; exit }' "$RELEASE")"
checkout_policy_line="$(awk 'index($0, "- name: Checkout verification policy") { print NR; exit }' "$RELEASE")"
archive_line="$(awk 'index($0, "-C release-staging -cf - verified-dist") { print NR; exit }' "$RELEASE")"
checksum_line="$(awk 'index($0, "sha256sum -c \"$archive_basename.sha256\"") { print NR; exit }' "$RELEASE")"
extract_line="$(awk 'index($0, "tar -xzf \"release-staging/publish/$archive_basename\"") { print NR; exit }' "$RELEASE")"
unpacked_verify_line="$(awk 'index($0, "--verify-verified-dist \"$extract_dir/verified-dist\"") { print NR; exit }' "$RELEASE")"
last_bundle_copy_line="$(awk 'index($0, "release-staging/publish/archive.provenance.bundle.json") { print NR; exit }' "$RELEASE")"
release_create_line="$(awk 'index($0, "gh release create \"$GITHUB_REF_NAME\"") { print NR; exit }' "$RELEASE")"
(( publish_line < checkout_policy_line && checkout_policy_line < source_verify_first_line && source_verify_first_line < archive_line && archive_line < checksum_line && checksum_line < extract_line && extract_line < unpacked_verify_line && unpacked_verify_line < last_bundle_copy_line && last_bundle_copy_line < source_verify_last_line && source_verify_last_line < release_create_line )) || {
  echo 'verified-dist archive/checksum/unpack/reverification/release ordering is unsafe' >&2; exit 1
}

[[ "$(grep -c 'contents: write' "$RELEASE")" == 1 ]] || { echo 'release write permission is not isolated to one job' >&2; exit 1; }
[[ "$(grep -Fc 'PIPESTATUS[@]' "$ROOT_DIR/scripts/build.sh")" == 2 ]] || { echo 'build pipelines do not capture both pipeline exit statuses' >&2; exit 1; }
grep -Fq 'download_tee_status' "$ROOT_DIR/scripts/build.sh"
grep -Fq 'build_tee_status' "$ROOT_DIR/scripts/build.sh"
policy_tmp="$(mktemp -d "$ROOT_DIR/.work/test-build-path-policy.XXXXXX")"
outside_tmp="$(mktemp -d)"
trap 'rm -rf "$policy_tmp" "$outside_tmp"' EXIT
if WORK_DIR="$outside_tmp/outside-work" BUILD_LOG="$ROOT_DIR/build-policy.log" "$ROOT_DIR/scripts/build.sh" >"$policy_tmp/stdout" 2>"$policy_tmp/stderr"; then
  echo 'build accepted a work directory outside .work' >&2; exit 1
fi
grep -Fq 'Unsafe WORK_DIR' "$policy_tmp/stderr"
if WORK_DIR="$ROOT_DIR/.work/build-path-policy" BUILD_LOG="$outside_tmp/outside.log" "$ROOT_DIR/scripts/build.sh" >"$policy_tmp/stdout" 2>"$policy_tmp/stderr"; then
  echo 'build accepted a log path outside safe build-log roots' >&2; exit 1
fi
grep -Fq 'Unsafe BUILD_LOG' "$policy_tmp/stderr"
! grep -Eq '^[[:space:]]*assert[[:space:]]' \
  "$ROOT_DIR/scripts/release.sh" \
  "$ROOT_DIR/scripts/stage-nss-artifact.sh" \
  "$ROOT_DIR/scripts/compare-reproducible-builds.sh" \
  "$ROOT_DIR/scripts/validate.sh"
# Build commands must not appear after the publish job starts.
! awk '/^  publish:/{p=1} p' "$RELEASE" | grep -Eq 'scripts/(build|prepare)\.sh'
echo 'GitHub workflow least-privilege, reproducibility, and approval policy: OK'
