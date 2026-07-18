#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; BUILD="$ROOT_DIR/.github/workflows/build.yml"; RELEASE="$ROOT_DIR/.github/workflows/release.yml"; RELEASE_DOCS="$ROOT_DIR/docs/RELEASES.md"
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
grep -Fq -- "-H 'X-GitHub-Api-Version: 2026-03-10'" "$RELEASE"
grep -Fq 'IMMUTABLE_RELEASES_READ_TOKEN: ${{ secrets.IMMUTABLE_RELEASES_READ_TOKEN }}' "$RELEASE"
grep -Fq 'test -n "$IMMUTABLE_RELEASES_READ_TOKEN"' "$RELEASE"
grep -Fq 'GH_TOKEN="$IMMUTABLE_RELEASES_READ_TOKEN" gh api \' "$RELEASE"
grep -Fq '"repos/$GITHUB_REPOSITORY/immutable-releases"' "$RELEASE"
grep -Fq -- "--jq 'select(.enabled == true) | .enabled' | grep -Fxq true" "$RELEASE"
[[ "$(grep -Fc 'IMMUTABLE_RELEASES_READ_TOKEN' "$RELEASE")" == 3 ]] || {
  echo 'immutable releases read secret is referenced outside its isolated step contract' >&2; exit 1
}
python3 - "$RELEASE" <<'PY_IMMUTABLE_STEP_POLICY'
import pathlib
import sys

lines = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
step_starts = [i for i, line in enumerate(lines) if line.startswith("      - name: ")]

def step(name: str) -> tuple[int, int, list[str]]:
    start = next(i for i in step_starts if lines[i] == f"      - name: {name}")
    end = next((i for i in step_starts if i > start), len(lines))
    return start, end, lines[start:end]

checkout_start, checkout_end, checkout = step("Checkout trusted tag")
immutable_start, immutable_end, immutable = step("Require repository immutable releases")
tag_start, tag_end, tag_policy = step("Verify trusted tag, derive flavor, and run policy tests")
if not checkout_start < immutable_start < tag_start:
    raise SystemExit("immutable secret step is not between trusted checkout and tag policy")
secret_name = "IMMUTABLE_RELEASES_READ_TOKEN"
secret_lines = [i for i, line in enumerate(lines) if secret_name in line]
if len(secret_lines) != 3 or not all(immutable_start < i < immutable_end for i in secret_lines):
    raise SystemExit("immutable releases secret escaped its dedicated step")
if any(secret_name in line for line in checkout + tag_policy):
    raise SystemExit("checkout or tag policy step inherited the immutable releases secret")
immutable_text = "\n".join(immutable)
tag_text = "\n".join(tag_policy)
for required in (
    "IMMUTABLE_RELEASES_READ_TOKEN: ${{ secrets.IMMUTABLE_RELEASES_READ_TOKEN }}",
    'test -n "$IMMUTABLE_RELEASES_READ_TOKEN"',
    'GH_TOKEN="$IMMUTABLE_RELEASES_READ_TOKEN" gh api',
    '"repos/$GITHUB_REPOSITORY/immutable-releases"',
):
    if required not in immutable_text:
        raise SystemExit(f"immutable step is missing required isolation control: {required}")
if "GH_TOKEN: ${{ github.token }}" in immutable_text:
    raise SystemExit("immutable secret step also received the normal workflow token")
for required in (
    "id: release_identity",
    "GH_TOKEN: ${{ github.token }}",
    "official_tag_pattern=",
    "release_tag_is_absent()",
    'release_tag_is_absent "$GITHUB_REF_NAME"',
    'python3 scripts/device_metadata.py',
    '--device xiaomi-ax9000',
    '--flavor "$flavor"',
    '--channel ram-test',
    'NEXAWRT_FLAVOR="$flavor" ./tests/test_static.sh',
):
    if required not in tag_text:
        raise SystemExit(f"tag policy step is missing required operation: {required}")
PY_IMMUTABLE_STEP_POLICY
grep -Fq 'cancel-in-progress: false' "$RELEASE"
tag_entry_count="$(awk '/^    tags:/{tags=1; next} tags && /^      - /{count++; next} tags{exit} END{print count+0}' "$RELEASE")"
[[ "$tag_entry_count" == 2 ]] || { echo 'release workflow exposes an unexpected tag trigger' >&2; exit 1; }
[[ "$(grep -Ec "^[[:space:]]+- 'ram-test(-nss)?-v\*'" "$RELEASE")" == 2 ]] || { echo 'release workflow does not expose exactly the official and NSS tag families' >&2; exit 1; }
grep -Fq -- "- 'ram-test-v*'" "$RELEASE"
grep -Fq -- "- 'ram-test-nss-v*'" "$RELEASE"
official_tag_pattern='^ram-test-(v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)-rc\.(0|[1-9][0-9]*))$'
nss_tag_pattern='^ram-test-nss-(v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)-rc\.(0|[1-9][0-9]*))$'
grep -Fq "official_tag_pattern='$official_tag_pattern'" "$RELEASE"
grep -Fq "nss_tag_pattern='$nss_tag_pattern'" "$RELEASE"
while IFS='|' read -r trusted_tag expected_flavor expected_version; do
  if [[ "$trusted_tag" =~ $official_tag_pattern ]]; then
    actual_flavor=official
    actual_version="${BASH_REMATCH[1]}"
  elif [[ "$trusted_tag" =~ $nss_tag_pattern ]]; then
    actual_flavor=nss
    actual_version="${BASH_REMATCH[1]}"
  else
    echo "trusted versioned prerelease tag was rejected: $trusted_tag" >&2
    exit 1
  fi
  [[ "$actual_flavor" == "$expected_flavor" ]] || { echo "wrong flavor for $trusted_tag" >&2; exit 1; }
  [[ "$actual_version" == "$expected_version" ]] || { echo "wrong release version for $trusted_tag" >&2; exit 1; }
done <<'TRUSTED_TAGS'
ram-test-v0.0.0-rc.0|official|v0.0.0-rc.0
ram-test-v1.2.3-rc.4|official|v1.2.3-rc.4
ram-test-v10.20.300-rc.40|official|v10.20.300-rc.40
ram-test-nss-v0.0.0-rc.0|nss|v0.0.0-rc.0
ram-test-nss-v1.2.3-rc.4|nss|v1.2.3-rc.4
ram-test-nss-v10.20.300-rc.40|nss|v10.20.300-rc.40
TRUSTED_TAGS
while IFS= read -r untrusted_tag; do
  ! [[ "$untrusted_tag" =~ $official_tag_pattern || "$untrusted_tag" =~ $nss_tag_pattern ]] || { echo "untrusted tag matches a release flavor: $untrusted_tag" >&2; exit 1; }
done <<'UNTRUSTED_TAGS'
ram-test-v
ram-test-nss-v
ram-test-v1
ram-test-v1.2.3
ram-test-v1.2.3-rc
ram-test-v1.2.3-rc1
ram-test-v1.2.3-rc.
ram-test-v1.2.3-rc.01
ram-test-v01.2.3-rc.1
ram-test-v1.02.3-rc.1
ram-test-v1.2.03-rc.1
ram-test-v1.2.3-rc.1-extra
ram-test-v1.2.3-RC.1
ram-test-v1_2_3-rc.1
ram-test-v1.2.3.rc.1
ram-test-v1.2.3-rc.-1
ram-test-v1.2.3-rc.+1
ram-test-v1.2.3-rc.1/other
ram-test-nss-v01.2.3-rc.1
ram-test-nss-v1.02.3-rc.1
ram-test-nss-v1.2.03-rc.1
ram-test-nss-v1.2.3-rc.01
ram-test-nss-v1.2.3-rc.1-extra
ram-test-debug-v1.2.3-rc.1
UNTRUSTED_TAGS
workflow_tmp="$(mktemp -d)"
trap 'rm -rf "$workflow_tmp"' EXIT
python3 - "$RELEASE" "$workflow_tmp/release-helper.sh" <<'PY_RELEASE_HELPER'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
start = next(i for i, line in enumerate(source) if line.strip() == "release_tag_is_absent() {")
body = []
for line in source[start:]:
    if not line.startswith("          "):
        raise SystemExit("release helper indentation is unsafe")
    stripped = line[10:]
    body.append(stripped)
    if stripped == "}":
        break
else:
    raise SystemExit("release helper terminator is missing")
pathlib.Path(sys.argv[2]).write_text("\n".join(body) + "\n", encoding="utf-8")
PY_RELEASE_HELPER
mkdir "$workflow_tmp/bin"
cat > "$workflow_tmp/bin/gh" <<'GH_FIXTURE'
#!/usr/bin/env bash
case "${GH_RELEASE_FIXTURE:-}" in
  exists) printf 'existing release\n'; exit 0 ;;
  missing) printf 'release not found\n' >&2; exit 1 ;;
  http404) printf 'HTTP 404 Not Found\n' >&2; exit 1 ;;
  auth) printf 'HTTP 401: Bad credentials\n' >&2; exit 1 ;;
  network) printf 'error connecting to api.github.com\n' >&2; exit 1 ;;
  rate-limit) printf 'HTTP 403: API rate limit exceeded\n' >&2; exit 1 ;;
  host-not-found) printf 'api.github.com: host not found\n' >&2; exit 1 ;;
  *) exit 2 ;;
esac
GH_FIXTURE
chmod +x "$workflow_tmp/bin/gh"
release_helper() {
  PATH="$workflow_tmp/bin:$PATH" GH_RELEASE_FIXTURE="$1"     bash -euo pipefail -c 'source "$1"; release_tag_is_absent ram-test-v1' bash "$workflow_tmp/release-helper.sh"
}
release_helper missing
release_helper http404
if release_helper exists >"$workflow_tmp/stdout" 2>"$workflow_tmp/stderr"; then
  echo 'release helper accepted an existing release' >&2; exit 1
fi
grep -Fq 'Release already exists' "$workflow_tmp/stderr"
for fixture in auth network rate-limit host-not-found; do
  if release_helper "$fixture" >"$workflow_tmp/stdout" 2>"$workflow_tmp/stderr"; then
    echo "release helper accepted unsafe gh result: $fixture" >&2; exit 1
  fi
  grep -Fq 'Unable to determine whether release exists' "$workflow_tmp/stderr"
done
python3 - "$RELEASE" "$workflow_tmp/draft-id-check.py" "$workflow_tmp/draft-assets-check.py" <<'PY_DRAFT_RELEASE_HELPERS'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()

def extract(start_text: str, output_path: str) -> None:
    start = next(i for i, line in enumerate(source) if line.strip() == start_text)
    body = []
    for line in source[start + 1:]:
        if line.strip() == "PY":
            break
        if not line:
            body.append("")
            continue
        if not line.startswith("          "):
            raise SystemExit(f"release assertion indentation is unsafe: {start_text}")
        body.append(line[10:])
    else:
        raise SystemExit(f"release assertion terminator is missing: {start_text}")
    pathlib.Path(output_path).write_text("\n".join(body) + "\n", encoding="utf-8")

extract(
    'release_id="$(python3 - "$draft_release" "$GITHUB_REF_NAME" <<\'PY\'',
    sys.argv[2],
)
extract(
    'DRAFT_EXPECTED_ASSETS="$expected" python3 - "$draft_assets" <<\'PY\'',
    sys.argv[3],
)
PY_DRAFT_RELEASE_HELPERS
python3 - "$workflow_tmp" <<'PY_DRAFT_RELEASE_FIXTURES'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
tag = "ram-test-v1.2.3-rc.4"
valid_id = {"databaseId": 424242, "isDraft": True, "isPrerelease": True, "tagName": tag}
id_fixtures = {
    "valid": valid_id,
    "id-bool": {**valid_id, "databaseId": True},
    "id-zero": {**valid_id, "databaseId": 0},
    "id-string": {**valid_id, "databaseId": "424242"},
    "draft": {**valid_id, "isDraft": False},
    "prerelease": {**valid_id, "isPrerelease": False},
    "tag": {**valid_id, "tagName": "ram-test-v1.2.3-rc.5"},
}
for name, value in id_fixtures.items():
    (root / f"draft-id-{name}.json").write_text(json.dumps(value), encoding="utf-8")

assets = [
    {"name": "archive.tar.gz", "state": "uploaded", "size": 100},
    {"name": "archive.tar.gz.sha256", "state": "uploaded", "size": 101},
    {"name": "archive.provenance.bundle.json", "state": "uploaded", "size": 102},
    {"name": "checksums.provenance.bundle.json", "state": "uploaded", "size": 103},
    {"name": "firmware.provenance.bundle.json", "state": "uploaded", "size": 104},
    {"name": "sbom.provenance.bundle.json", "state": "uploaded", "size": 105},
]
asset_fixtures = {
    "valid": assets,
    "extra": [*assets, {"name": "unexpected.bin", "state": "uploaded", "size": 1}],
    "missing": assets[:-1],
    "duplicate": [*assets[:-1], assets[-2]],
    "state": [*assets[:-1], {**assets[-1], "state": "new"}],
    "size-zero": [*assets[:-1], {**assets[-1], "size": 0}],
    "size-bool": [*assets[:-1], {**assets[-1], "size": True}],
    "malformed": [*assets[:-1], "not-an-object"],
    "name": [*assets[:-1], {**assets[-1], "name": ""}],
}
for name, value in asset_fixtures.items():
    (root / f"draft-assets-{name}.json").write_text(json.dumps(value), encoding="utf-8")
(root / "draft-expected-assets.txt").write_text(
    "\n".join(asset["name"] for asset in assets) + "\n", encoding="utf-8"
)
PY_DRAFT_RELEASE_FIXTURES
[[ "$(python3 "$workflow_tmp/draft-id-check.py" "$workflow_tmp/draft-id-valid.json" ram-test-v1.2.3-rc.4)" == 424242 ]]
for fixture in id-bool id-zero id-string draft prerelease tag; do
  if python3 "$workflow_tmp/draft-id-check.py" "$workflow_tmp/draft-id-$fixture.json" ram-test-v1.2.3-rc.4 >"$workflow_tmp/stdout" 2>"$workflow_tmp/stderr"; then
    echo "draft release identity assertion accepted invalid state: $fixture" >&2; exit 1
  fi
done
draft_expected_assets="$(cat "$workflow_tmp/draft-expected-assets.txt")"
DRAFT_EXPECTED_ASSETS="$draft_expected_assets" python3 "$workflow_tmp/draft-assets-check.py" "$workflow_tmp/draft-assets-valid.json"
for fixture in extra missing duplicate state size-zero size-bool malformed name; do
  if DRAFT_EXPECTED_ASSETS="$draft_expected_assets" python3 "$workflow_tmp/draft-assets-check.py" "$workflow_tmp/draft-assets-$fixture.json" >"$workflow_tmp/stdout" 2>"$workflow_tmp/stderr"; then
    echo "draft release asset assertion accepted invalid state: $fixture" >&2; exit 1
  fi
done
if DRAFT_EXPECTED_ASSETS='' python3 "$workflow_tmp/draft-assets-check.py" "$workflow_tmp/draft-assets-valid.json" >"$workflow_tmp/stdout" 2>"$workflow_tmp/stderr"; then
  echo 'draft release asset assertion accepted an empty expected set' >&2; exit 1
fi
python3 - "$RELEASE" "$workflow_tmp/final-release-check.py" <<'PY_FINAL_RELEASE_HELPER'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
start = next(
    i for i, line in enumerate(source)
    if line.strip() == "python3 - \"$final_release_by_id\" \"$final_release_by_tag\" \"$release_id\" \"$GITHUB_REF_NAME\" \"$RELEASE_FLAVOR\" \"$RELEASE_VERSION\" <<'PY'"
)
body = []
for line in source[start + 1:]:
    if line.strip() == "PY":
        break
    if not line:
        body.append("")
        continue
    if not line.startswith("          "):
        raise SystemExit("final release assertion indentation is unsafe")
    body.append(line[10:])
else:
    raise SystemExit("final release assertion terminator is missing")
pathlib.Path(sys.argv[2]).write_text("\n".join(body) + "\n", encoding="utf-8")
PY_FINAL_RELEASE_HELPER
python3 - "$workflow_tmp" <<'PY_FINAL_RELEASE_FIXTURES'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
tag = "ram-test-v1.2.3-rc.4"
archive = "NexaWrt-AX9000-official-v1.2.3-rc.4-verified-dist.tar.gz"
assets = [
    {"name": archive, "state": "uploaded", "size": 100},
    {"name": f"{archive}.sha256", "state": "uploaded", "size": 101},
    {"name": "archive.provenance.bundle.json", "state": "uploaded", "size": 102},
    {"name": "checksums.provenance.bundle.json", "state": "uploaded", "size": 103},
    {"name": "firmware.provenance.bundle.json", "state": "uploaded", "size": 104},
    {"name": "sbom.provenance.bundle.json", "state": "uploaded", "size": 105},
]
valid = {
    "id": 424242,
    "draft": False,
    "prerelease": True,
    "immutable": True,
    "tag_name": tag,
    "published_at": "2026-07-17T01:02:03Z",
    "assets": assets,
}
fixtures = {
    "valid": valid,
    "id": {**valid, "id": 424243},
    "draft": {**valid, "draft": True},
    "prerelease": {**valid, "prerelease": False},
    "mutable": {**valid, "immutable": False},
    "tag": {**valid, "tag_name": "ram-test-v1.2.3-rc.5"},
    "published-null": {**valid, "published_at": None},
    "published-format": {**valid, "published_at": "2026-07-17"},
    "asset-extra": {**valid, "assets": [*assets, {"name": "sysupgrade.bin", "state": "uploaded", "size": 1}]},
    "asset-missing": {**valid, "assets": assets[:-1]},
    "asset-duplicate": {**valid, "assets": [*assets[:-1], assets[-2]]},
    "asset-state": {**valid, "assets": [*assets[:-1], {**assets[-1], "state": "new"}]},
    "asset-size": {**valid, "assets": [*assets[:-1], {**assets[-1], "size": 0}]},
}
for name, value in fixtures.items():
    (root / f"final-{name}.json").write_text(json.dumps(value), encoding="utf-8")
PY_FINAL_RELEASE_FIXTURES
python3 "$workflow_tmp/final-release-check.py" "$workflow_tmp/final-valid.json" "$workflow_tmp/final-valid.json" 424242 ram-test-v1.2.3-rc.4 official v1.2.3-rc.4
for fixture in id draft prerelease mutable tag published-null published-format asset-extra asset-missing asset-duplicate asset-state asset-size; do
  if python3 "$workflow_tmp/final-release-check.py" "$workflow_tmp/final-$fixture.json" "$workflow_tmp/final-valid.json" 424242 ram-test-v1.2.3-rc.4 official v1.2.3-rc.4 >"$workflow_tmp/stdout" 2>"$workflow_tmp/stderr"; then
    echo "final release assertion accepted invalid state: $fixture" >&2; exit 1
  fi
done
if python3 "$workflow_tmp/final-release-check.py" "$workflow_tmp/final-valid.json" "$workflow_tmp/final-id.json" 424242 ram-test-v1.2.3-rc.4 official v1.2.3-rc.4 >"$workflow_tmp/stdout" 2>"$workflow_tmp/stderr"; then
  echo 'final release assertion accepted a mismatched by-tag release ID' >&2; exit 1
fi
grep -Fq 'Untrusted release tag name' "$RELEASE"
grep -Fq 'flavor=official' "$RELEASE"
grep -Fq 'flavor=nss' "$RELEASE"
grep -Fq 'work_basename=openwrt' "$RELEASE"
grep -Fq 'work_basename=openwrt-nss' "$RELEASE"
grep -Fq 'staging_basename=dist' "$RELEASE"
grep -Fq 'staging_basename=dist-nss' "$RELEASE"
grep -Fq 'flavor: ${{ steps.release_identity.outputs.flavor }}' "$RELEASE"
grep -Fq 'release_version: ${{ steps.release_identity.outputs.release_version }}' "$RELEASE"
grep -Fq 'release_version="${BASH_REMATCH[1]}"' "$RELEASE"
grep -Fq "printf 'flavor=%s\nrelease_version=%s\nwork_basename=%s\nstaging_basename=%s\n'" "$RELEASE"
grep -Fq '"$flavor" "$release_version" "$work_basename" "$staging_basename" >> "$GITHUB_OUTPUT"' "$RELEASE"
grep -Fq 'NEXAWRT_FLAVOR: ${{ needs.preflight.outputs.flavor }}' "$RELEASE"
grep -Fq 'RELEASE_VERSION: ${{ needs.preflight.outputs.release_version }}' "$RELEASE"
grep -Fq 'NEXAWRT_BUILD_REPLICA: ${{ matrix.replica }}' "$RELEASE"
! grep -Eq 'NEXAWRT_APK_SIGNING_KEY_PEM|NEXAWRT_APK_SIGNING_KEY_FILE|BUILD_KEY_APK_SEC|secrets\.NEXAWRT_APK_SIGNING' "$RELEASE" || {
  echo 'release workflow still references APK private or secret signing material' >&2; exit 1
}
grep -Fq 'Require committed production APK public trust identity' "$RELEASE"
grep -Fq 'nexawrt_validate_lock_file manifests/apk-signing.lock apk-signing' "$RELEASE"
grep -Fq 'source manifests/apk-signing.lock' "$RELEASE"
grep -Fq 'public_key="$(pwd -P)/manifests/apk-signing-public.pem"' "$RELEASE"
grep -Fq 'NEXAWRT_APK_SIGNING_PUBLIC_SHA256="$production_anchor"' "$RELEASE"
grep -Fq 'NEXAWRT_APK_SIGNING_PUBLIC_KEY_FILE="$public_key"' "$RELEASE"
grep -Fq 'NEXAWRT_APK_SIGNING_PRODUCTION_PUBLIC_SHA256' "$RELEASE"
grep -Fq "printf 'NEXAWRT_APK_SIGNING_PROFILE=production\\n'" "$RELEASE"
! grep -Fq "printf 'NEXAWRT_APK_SIGNING_PROFILE=repro-test\\n'" "$RELEASE"
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
grep -Fq 'test "$(git cat-file -t "refs/tags/$GITHUB_REF_NAME")" = commit' "$RELEASE"
grep -Fq 'test "$(git rev-parse "refs/tags/$GITHUB_REF_NAME")" = "$GITHUB_SHA"' "$RELEASE"
grep -Fq 'git/ref/tags/$GITHUB_REF_NAME' "$RELEASE"
grep -Fq 'test "$remote_type" = commit' "$RELEASE"
grep -Fq 'test "$remote_sha" = "$GITHUB_SHA"' "$RELEASE"
grep -Fq 'gh release create "$GITHUB_REF_NAME" --verify-tag --draft --prerelease --latest=false' "$RELEASE"
grep -Fq 'gh release view "$GITHUB_REF_NAME" --json databaseId,isDraft,isPrerelease,tagName > "$draft_release"' "$RELEASE"
grep -Fq 'release_id = release.get("databaseId")' "$RELEASE"
grep -Fq 'draft release database ID is invalid' "$RELEASE"
grep -Fq 'release.get("isDraft") is not True' "$RELEASE"
grep -Fq 'release.get("isPrerelease") is not True' "$RELEASE"
grep -Fq '"repos/$GITHUB_REPOSITORY/releases/$release_id/assets?per_page=100" > "$draft_assets"' "$RELEASE"
grep -Fq 'draft release asset count is not exact' "$RELEASE"
grep -Fq 'draft release asset names are not the exact expected set' "$RELEASE"
grep -Fq 'draft release asset is not uploaded' "$RELEASE"
grep -Fq 'draft release asset size is invalid' "$RELEASE"
! grep -Fq 'actual="$(gh api "repos/$GITHUB_REPOSITORY/releases/tags/$GITHUB_REF_NAME"' "$RELEASE"
! grep -Fq 'gh release edit "$GITHUB_REF_NAME"' "$RELEASE"
grep -Fq -- '--method PATCH' "$RELEASE"
grep -Fq '"repos/$GITHUB_REPOSITORY/releases/$release_id" \' "$RELEASE"
grep -Fq 'published release {lookup} does not match the draft release ID' "$RELEASE"
[[ "$(grep -Fc -- '--latest=false' "$RELEASE")" == 1 ]] || { echo 'draft creation does not explicitly disable latest' >&2; exit 1; }
grep -Fq -- '-f make_latest=false > /dev/null' "$RELEASE"
grep -Fq 'official) release_title="NexaWrt AX9000 $RELEASE_VERSION RAM-test prerelease"' "$RELEASE"
grep -Fq 'nss) release_title="NexaWrt AX9000 NSS $RELEASE_VERSION RAM-test prerelease"' "$RELEASE"
grep -Fq -- '--title "$release_title"' "$RELEASE"
! grep -Fq -- '--title "$GITHUB_REF_NAME"' "$RELEASE"
grep -Fq 'release.get("draft") is not False' "$RELEASE"
grep -Fq 'release.get("prerelease") is not True' "$RELEASE"
grep -Fq 'release.get("immutable") is not True' "$RELEASE"
grep -Fq 'published release {lookup} asset count is not exact' "$RELEASE"
grep -Fq 'published release {lookup} asset names are not the exact expected set' "$RELEASE"
grep -Fq 'release.get("tag_name") != expected_tag' "$RELEASE"
grep -Fq 'published_at = release.get("published_at")' "$RELEASE"
grep -Fq 'published release {lookup} has no valid published_at timestamp' "$RELEASE"
grep -Fq '"repos/$GITHUB_REPOSITORY/releases/$release_id" > "$final_release_by_id"' "$RELEASE"
grep -Fq '"repos/$GITHUB_REPOSITORY/releases/tags/$GITHUB_REF_NAME" > "$final_release_by_tag"' "$RELEASE"
test -f "$RELEASE_DOCS"
grep -Fq 'ram-test-vMAJOR.MINOR.PATCH-rc.N' "$RELEASE_DOCS"
grep -Fq 'ram-test-nss-vMAJOR.MINOR.PATCH-rc.N' "$RELEASE_DOCS"
grep -Fq 'lightweight tags' "$RELEASE_DOCS"
grep -Fq 'NexaWrt-AX9000-official-v1.4.0-rc.1-verified-dist.tar.gz.sha256' "$RELEASE_DOCS"
grep -Fq 'NexaWrt-AX9000-nss-v1.4.0-rc.1-verified-dist.tar.gz.sha256' "$RELEASE_DOCS"
grep -Fq '## Release procedure' "$RELEASE_DOCS"
grep -Fq '## Draft recovery' "$RELEASE_DOCS"
grep -Fq 'does not expose draft releases' "$RELEASE_DOCS"
grep -Fq 'Do not move or recreate the failed tag' "$RELEASE_DOCS"
grep -Fq 'gh release delete "$tag" --yes' "$RELEASE_DOCS"
grep -Fq 'attestations: write' "$RELEASE"
[[ "$(grep -c '^      artifact-metadata: write$' "$RELEASE")" == 2 ]] || { echo 'release artifact metadata write permission is not limited to producer and publish jobs' >&2; exit 1; }
grep -Fq 'actions/attest-build-provenance@96278af6caaf10aea03fd8d33a09a777ca52d62f' "$RELEASE"
[[ "$(grep -Fc 'actions/attest-build-provenance@96278af6caaf10aea03fd8d33a09a777ca52d62f' "$RELEASE")" == 5 ]] || {
  echo 'release workflow must attest each producer descriptor plus the four publish subjects' >&2; exit 1
}
grep -Fq 'subject-path: release-staging/replica-provenance-${{ matrix.replica }}/producer-descriptor.json' "$RELEASE"
grep -Fq '"repository": "tifycloud/NexaWrt"' "$RELEASE"
grep -Fq '"workflow": "tifycloud/NexaWrt/.github/workflows/release.yml"' "$RELEASE"
grep -Fq 'test "$GITHUB_REF" = "refs/tags/$GITHUB_REF_NAME"' "$RELEASE"
grep -Fq 'test "$GITHUB_WORKFLOW_REF" = "tifycloud/NexaWrt/.github/workflows/release.yml@$GITHUB_REF"' "$RELEASE"
grep -Fq 'test "$GITHUB_WORKFLOW_SHA" = "$GITHUB_SHA"' "$RELEASE"
grep -Fq '"schema": 2' "$RELEASE"
for field in schema repository workflow workflow_ref source_ref source_digest signer_digest run_id run_attempt flavor replica_id artifact_id artifact_name receipt_filename receipt_sha256; do
  grep -Fq "\"$field\"" "$RELEASE" || { echo "producer descriptor field missing: $field" >&2; exit 1; }
done
grep -Fq 'replica-provenance-${{ github.run_id }}-${{ github.run_attempt }}-${{ needs.preflight.outputs.flavor }}-${{ matrix.replica }}' "$RELEASE"
grep -Fq 'producer-descriptor.provenance.bundle.json' "$RELEASE"
grep -Fq 'attestations: read' "$RELEASE"
[[ "$(grep -c '^      actions: read$' "$RELEASE")" == 1 ]] || { echo 'release compare must have actions: read exactly once' >&2; exit 1; }
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
for flag in --source-digest --source-ref --signer-digest; do
  grep -Fq -- '"'$flag'"' "$ROOT_DIR/scripts/compare-reproducible-builds.sh" || { echo "comparator missing attestation constraint: $flag" >&2; exit 1; }
done
grep -Fq 'apk_signing_mode=public-key-only' "$ROOT_DIR/scripts/compare-reproducible-builds.sh"
grep -Fq 'apk_index_signed=false' "$ROOT_DIR/scripts/compare-reproducible-builds.sh"
! grep -Fq '/usr/bin/python3' "$ROOT_DIR/scripts/compare-reproducible-builds.sh"
grep -Fq 'sys.executable' "$ROOT_DIR/scripts/compare-reproducible-builds.sh"

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
grep -Fq -- 'tar --format=ustar --sort=name --owner=0 --group=0 --numeric-owner --mtime="@$source_epoch"' "$RELEASE"
grep -Fq -- '-C release-staging -cf - verified-dist | gzip -9n > "release-staging/publish/$archive_basename"' "$RELEASE"
! grep -Fq 'tar --sort=name --owner=0 --group=0 --numeric-owner' "$RELEASE"
grep -Fq 'sha256sum "$archive_basename" > "$archive_basename.sha256"' "$RELEASE"
grep -Fq 'sha256sum -c "$archive_basename.sha256"' "$RELEASE"
grep -Fq 'tar -xzf "release-staging/publish/$archive_basename" -C "$extract_dir"' "$RELEASE"
grep -Fq 'archive_basename="NexaWrt-AX9000-${RELEASE_FLAVOR}-${RELEASE_VERSION}-verified-dist.tar.gz"' "$RELEASE"
grep -Fq 'subject-path: release-staging/publish/NexaWrt-AX9000-${{ needs.preflight.outputs.flavor }}-${{ needs.preflight.outputs.release_version }}-verified-dist.tar.gz' "$RELEASE"
! grep -Fq 'NexaWrt-AX9000-${RELEASE_FLAVOR}-verified-dist.tar.gz' "$RELEASE"
! grep -Fq 'NexaWrt-AX9000-${{ needs.preflight.outputs.flavor }}-verified-dist.tar.gz' "$RELEASE"
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
draft_fetch_line="$(awk 'index($0, "gh release view \"$GITHUB_REF_NAME\" --json databaseId,isDraft,isPrerelease,tagName") { print NR; exit }' "$RELEASE")"
draft_state_line="$(awk 'index($0, "release.get(\"isDraft\") is not True") { print NR; exit }' "$RELEASE")"
release_upload_line="$(awk 'index($0, "gh release upload \"$GITHUB_REF_NAME\"") { print NR; exit }' "$RELEASE")"
draft_assets_line="$(awk 'index($0, "releases/$release_id/assets?per_page=100") { print NR; exit }' "$RELEASE")"
draft_assets_state_line="$(awk 'index($0, "draft release asset count is not exact") { print NR; exit }' "$RELEASE")"
release_patch_line="$(awk 'index($0, "--method PATCH") { print NR; exit }' "$RELEASE")"
final_id_fetch_line="$(awk 'index($0, "releases/$release_id\" > \"$final_release_by_id\"") { print NR; exit }' "$RELEASE")"
final_tag_fetch_line="$(awk 'index($0, "releases/tags/$GITHUB_REF_NAME\" > \"$final_release_by_tag\"") { print NR; exit }' "$RELEASE")"
final_state_line="$(awk 'index($0, "release.get(\"draft\") is not False") { print NR; exit }' "$RELEASE")"
published_at_line="$(awk 'index($0, "published_at = release.get(\"published_at\")") { print NR; exit }' "$RELEASE")"
(( publish_line < checkout_policy_line && checkout_policy_line < source_verify_first_line && source_verify_first_line < archive_line && archive_line < checksum_line && checksum_line < extract_line && extract_line < unpacked_verify_line && unpacked_verify_line < last_bundle_copy_line && last_bundle_copy_line < source_verify_last_line && source_verify_last_line < release_create_line && release_create_line < draft_fetch_line && draft_fetch_line < draft_state_line && draft_state_line < release_upload_line && release_upload_line < draft_assets_line && draft_assets_line < draft_assets_state_line && draft_assets_state_line < release_patch_line && release_patch_line < final_id_fetch_line && final_id_fetch_line < final_tag_fetch_line && final_tag_fetch_line < final_state_line && final_state_line < published_at_line )) || {
  echo 'verified-dist packaging, exact asset verification, publication, and final-state verification ordering is unsafe' >&2; exit 1
}

[[ "$(grep -c 'contents: write' "$RELEASE")" == 1 ]] || { echo 'release write permission is not isolated to one job' >&2; exit 1; }
[[ "$(grep -Fc 'PIPESTATUS[@]' "$ROOT_DIR/scripts/build.sh")" == 2 ]] || { echo 'build pipelines do not capture both pipeline exit statuses' >&2; exit 1; }
grep -Fq 'download_tee_status' "$ROOT_DIR/scripts/build.sh"
grep -Fq 'build_tee_status' "$ROOT_DIR/scripts/build.sh"
policy_tmp="$(mktemp -d "$ROOT_DIR/.work/test-build-path-policy.XXXXXX")"
outside_tmp="$(mktemp -d)"
trap 'rm -rf "$workflow_tmp" "$policy_tmp" "$outside_tmp"' EXIT
if WORK_DIR="$outside_tmp/outside-work" BUILD_LOG="$ROOT_DIR/build-policy.log" bash "$ROOT_DIR/scripts/build.sh" >"$policy_tmp/stdout" 2>"$policy_tmp/stderr"; then
  echo 'build accepted a work directory outside .work' >&2; exit 1
fi
grep -Fq 'Unsafe WORK_DIR' "$policy_tmp/stderr"
if WORK_DIR="$ROOT_DIR/.work/build-path-policy" BUILD_LOG="$outside_tmp/outside.log" bash "$ROOT_DIR/scripts/build.sh" >"$policy_tmp/stdout" 2>"$policy_tmp/stderr"; then
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
