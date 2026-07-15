#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/nexawrt-build-evidence.XXXXXX")"
PATCH_INPUT_PROBE="$ROOT_DIR/patches/999-input-binding-probe.patch"
trap 'rm -f "$PATCH_INPUT_PROBE"; rm -rf "$TMP"' EXIT
fail() { echo "test_build_evidence_policy: $*" >&2; exit 1; }
expect_failure() { local label="$1"; shift; if "$@" >/dev/null 2>&1; then fail "$label unexpectedly passed"; fi; }

for script in prepare.sh build.sh validate.sh collect-build-evidence.sh release.sh stage-nss-artifact.sh compare-reproducible-builds.sh; do
  [[ "$(grep -Fxc 'source "$ROOT_DIR/scripts/sanitize-git-environment.sh"' "$ROOT_DIR/scripts/$script")" == 1 ]] ||
    fail "$script must source the shared Git environment sanitizer exactly once"
  [[ "$(grep -Fxc 'nexawrt_sanitize_git_environment' "$ROOT_DIR/scripts/$script")" == 1 ]] ||
    fail "$script must invoke the shared Git environment sanitizer exactly once"
done
[[ "$(grep -Fc 'export GIT_NO_REPLACE_OBJECTS=1' "$ROOT_DIR/scripts/sanitize-git-environment.sh")" == 1 ]] ||
  fail 'shared Git environment sanitizer must export GIT_NO_REPLACE_OBJECTS=1 exactly once'
grep -Fq 'git_history_overrides_absent "$WORK_DIR" "prepared OpenWrt source checkout"' \
  "$ROOT_DIR/scripts/build.sh" || fail 'build does not reject source replace/grafts metadata'
grep -Fq 'SOURCE_DATE_EPOCH="$(git show -s --format=%ct "$SOURCE_COMMIT")"' \
  "$ROOT_DIR/scripts/build.sh" || fail 'SOURCE_DATE_EPOCH is not derived from the verified commit'
grep -Fq 'git_history_overrides_absent "$SOURCE_DIR" "$NEXAWRT_FLAVOR source checkout"' \
  "$ROOT_DIR/scripts/validate.sh" || fail 'validate does not reject source replace/grafts metadata'
grep -Fq 'git_history_overrides_absent "$checkout" "feed checkout $feed"' \
  "$ROOT_DIR/scripts/validate.sh" || fail 'validate does not reject feed replace/grafts metadata'
grep -Fq '"$INPUT_LISTER" "$FLAVOR" > "$INPUT_LIST"' \
  "$ROOT_DIR/scripts/collect-build-evidence.sh" || fail 'collector does not use the shared build input lister'
grep -Fq 'scripts/list-build-inputs.sh' "$ROOT_DIR/scripts/list-build-inputs.sh" ||
  fail 'build input lister does not enumerate itself'

list_inputs() { "$ROOT_DIR/scripts/list-build-inputs.sh" "$1" | tr '\0' '\n'; }
printf 'probe\n' > "$PATCH_INPUT_PROBE"
official_inputs="$(list_inputs official)"
nss_inputs="$(list_inputs nss)"
grep -Fxq 'patches/999-input-binding-probe.patch' <<<"$official_inputs" || fail 'official input lister omits a newly applicable numeric patch'
grep -Fxq 'patches/999-input-binding-probe.patch' <<<"$nss_inputs" || fail 'NSS input lister omits a newly applicable numeric patch'
rm -f "$PATCH_INPUT_PROBE"
for required in \
  scripts/list-build-inputs.sh \
  scripts/sanitize-git-environment.sh \
  scripts/lock-file-policy.sh \
  scripts/git-metadata-policy.sh \
  scripts/check-kernel-build-identity.sh \
  scripts/compare-reproducible-builds.sh \
  .github/workflows/build.yml \
  .github/workflows/release.yml \
  scripts/ax9000-runtime-probe.sh \
  scripts/collect-production-state.sh \
  scripts/collect-runtime-evidence.sh \
  scripts/create-hardware-session.sh \
  scripts/run-ax9000-stress-gate.sh \
  scripts/verify-hardware-evidence.sh \
  scripts/verify-post-reboot-state.sh \
  scripts/verify-stress-evidence.sh; do
  grep -Fxq "$required" <<<"$official_inputs" || fail "official build inputs omit policy dependency: $required"
  grep -Fxq "$required" <<<"$nss_inputs" || fail "NSS build inputs omit policy dependency: $required"
done
grep -Fxq 'THIRD_PARTY_NOTICES.md' <<<"$nss_inputs" || fail 'NSS build inputs omit THIRD_PARTY_NOTICES.md'
if grep -Fxq 'THIRD_PARTY_NOTICES.md' <<<"$official_inputs"; then
  fail 'official build inputs unexpectedly include NSS-only THIRD_PARTY_NOTICES.md'
fi

for assignment in \
  'export KBUILD_BUILD_USER=nexawrt' \
  'export KBUILD_BUILD_HOST=builder' \
  'export KBUILD_BUILD_VERSION=0'; do
  [[ "$(grep -Fxc "$assignment" "$ROOT_DIR/scripts/build.sh")" == 1 ]] || fail "missing or duplicated deterministic kernel identity: $assignment"
done
line_user="$(grep -nF 'export KBUILD_BUILD_USER=nexawrt' "$ROOT_DIR/scripts/build.sh" | cut -d: -f1)"
line_host="$(grep -nF 'export KBUILD_BUILD_HOST=builder' "$ROOT_DIR/scripts/build.sh" | cut -d: -f1)"
line_version="$(grep -nF 'export KBUILD_BUILD_VERSION=0' "$ROOT_DIR/scripts/build.sh" | cut -d: -f1)"
(( line_user < line_host && line_host < line_version )) || fail 'deterministic KBUILD identity exports are not in the expected order'
grep -Fq "grep -Eq '(^|[^[:alnum:]_])(gh[pousr]_" "$ROOT_DIR/scripts/collect-build-evidence.sh" || fail 'build-log GitHub token scan is missing'
if grep -Fq "grep -Eiq '(^|[^[:alnum:]_])(gh[pousr]_" "$ROOT_DIR/scripts/collect-build-evidence.sh"; then
  fail 'build-log GitHub token scan became case-insensitive'
fi

BUILD_POLICY_REPO="$TMP/build-policy-repo"
BUILD_WRAPPERS="$TMP/build-wrappers"
mkdir -p "$BUILD_POLICY_REPO/scripts" "$BUILD_POLICY_REPO/.work/openwrt" "$BUILD_WRAPPERS"
BUILD_POLICY_REPO="$(cd "$BUILD_POLICY_REPO" && pwd -P)"
BUILD_WORK="$BUILD_POLICY_REPO/.work/openwrt"
cp "$ROOT_DIR/scripts/build.sh" "$BUILD_POLICY_REPO/scripts/build.sh"
cp "$ROOT_DIR/scripts/sanitize-git-environment.sh" "$BUILD_POLICY_REPO/scripts/sanitize-git-environment.sh"
cp "$ROOT_DIR/scripts/git-metadata-policy.sh" "$BUILD_POLICY_REPO/scripts/git-metadata-policy.sh"
cat > "$BUILD_POLICY_REPO/scripts/prepare.sh" <<'PREPARE'
#!/usr/bin/env bash
set -euo pipefail
[[ "${GIT_NO_REPLACE_OBJECTS:-}" == 1 ]]
PREPARE
cat > "$BUILD_POLICY_REPO/scripts/release.sh" <<'RELEASE'
#!/usr/bin/env bash
set -euo pipefail
[[ "${GIT_NO_REPLACE_OBJECTS:-}" == 1 ]]
RELEASE
cat > "$BUILD_WRAPPERS/git" <<'GIT'
#!/usr/bin/env bash
set -euo pipefail
[[ "${GIT_NO_REPLACE_OBJECTS:-}" == 1 ]] || exit 97
if [[ "${FAKE_GIT_SHOW:-0}" == 1 && " $* " == *' show '* ]]; then
  printf 'not-a-timestamp\n'
  exit 0
fi
exec "${REAL_GIT:?}" "$@"
GIT
cat > "$BUILD_WRAPPERS/make" <<'MAKE'
#!/usr/bin/env bash
set -euo pipefail
mkdir -p dl
MAKE
chmod +x "$BUILD_POLICY_REPO/scripts/"*.sh "$BUILD_WRAPPERS/git" "$BUILD_WRAPPERS/make"
"$(command -v git)" -C "$BUILD_WORK" init -q
"$(command -v git)" -C "$BUILD_WORK" config user.name tester
"$(command -v git)" -C "$BUILD_WORK" config user.email tester@example.invalid
"$(command -v git)" -C "$BUILD_WORK" remote add origin https://example.invalid/openwrt.git
printf 'source\n' > "$BUILD_WORK/tracked.txt"
"$(command -v git)" -C "$BUILD_WORK" add tracked.txt
GIT_AUTHOR_DATE='1700000000 +0000' GIT_COMMITTER_DATE='1700000000 +0000' \
  "$(command -v git)" -C "$BUILD_WORK" commit -qm source
build_source_head="$(git -C "$BUILD_WORK" rev-parse HEAD)"
printf 'r0-%s\n' "${build_source_head:0:8}" > "$BUILD_WORK/version"
run_fixture_build() {
  env PATH="$BUILD_WRAPPERS:$PATH" REAL_GIT="$(command -v git)" \
    ALLOW_UNSUPPORTED_HOST=1 NEXAWRT_FLAVOR=official WORK_DIR="$BUILD_WORK" \
    BUILD_LOG="$BUILD_POLICY_REPO/build.log" CLEAN_BUILD=0 JOBS=1 \
    "$BUILD_POLICY_REPO/scripts/build.sh"
}
run_fixture_build >/dev/null
grep -Fq 'source_date_epoch=1700000000' "$BUILD_POLICY_REPO/build.log" ||
  fail 'build did not record the verified commit timestamp'
mkdir -p "$BUILD_WORK/.git/refs/replace"
printf '%s\n' "$build_source_head" > "$BUILD_WORK/.git/refs/replace/$build_source_head"
expect_failure 'build loose source replace ref' run_fixture_build
rm -rf "$BUILD_WORK/.git/refs/replace"
expect_failure 'build invalid commit timestamp' env FAKE_GIT_SHOW=1 \
  PATH="$BUILD_WRAPPERS:$PATH" REAL_GIT="$(command -v git)" \
  ALLOW_UNSUPPORTED_HOST=1 NEXAWRT_FLAVOR=official WORK_DIR="$BUILD_WORK" \
  BUILD_LOG="$BUILD_POLICY_REPO/build.log" CLEAN_BUILD=0 JOBS=1 \
  "$BUILD_POLICY_REPO/scripts/build.sh"

mkdir -p "$TMP/work" "$TMP/dist"
git -C "$TMP/work" init -q
git -C "$TMP/work" config user.name tester
git -C "$TMP/work" config user.email tester@example.invalid
printf 'CONFIG_TEST=y\n' > "$TMP/work/.config"
git -C "$TMP/work" add .config
git -C "$TMP/work" commit -qm initial
git -C "$TMP/work" remote add origin https://example.invalid/openwrt.git

# Uppercase GHS_ is a known compiler/test-vector shape, not a lowercase GitHub token prefix.
printf 'compiler self-test vector: GHS_012345678901234567890123456789\n' > "$TMP/build.log"
"$ROOT_DIR/scripts/collect-build-evidence.sh" official "$TMP/work" "$TMP/dist" "$TMP/build.log" >/dev/null
[[ -s "$TMP/dist/EVIDENCE/build.log" ]] || fail 'uppercase GHS_ build log was not archived'

printf 'leaked token: %s_%s\n' ghp 012345678901234567890123456789 > "$TMP/build.log"
expect_failure 'lowercase ghp token' "$ROOT_DIR/scripts/collect-build-evidence.sh" official "$TMP/work" "$TMP/dist" "$TMP/build.log"
printf 'leaked token: %s_%s\n' github_pat 012345678901234567890123456789 > "$TMP/build.log"
expect_failure 'lowercase github_pat token' "$ROOT_DIR/scripts/collect-build-evidence.sh" official "$TMP/work" "$TMP/dist" "$TMP/build.log"

assert_collector_rejects() {
  local label="$1"
  expect_failure "$label" \
    "$ROOT_DIR/scripts/collect-build-evidence.sh" official "$TMP/work" "$TMP/dist" "$TMP/build.log"
}

mkdir -p "$TMP/work/.git/refs/replace"
printf '%s\n' "$(git -C "$TMP/work" rev-parse HEAD)" \
  > "$TMP/work/.git/refs/replace/$(git -C "$TMP/work" rev-parse HEAD)"
assert_collector_rejects 'collector loose source replace ref'
rm -rf "$TMP/work/.git/refs/replace"

cp "$TMP/work/.git/packed-refs" "$TMP/packed-refs.backup" 2>/dev/null || : > "$TMP/no-packed-refs"
git -C "$TMP/work" pack-refs --all
source_head="$(git -C "$TMP/work" rev-parse HEAD)"
printf '%s refs/replace/%s\n' "$source_head" "$source_head" >> "$TMP/work/.git/packed-refs"
assert_collector_rejects 'collector packed source replace ref'
if [[ -f "$TMP/packed-refs.backup" ]]; then
  mv "$TMP/packed-refs.backup" "$TMP/work/.git/packed-refs"
else
  rm -f "$TMP/work/.git/packed-refs"
fi

ln -s "$TMP/missing-replace-target" "$TMP/work/.git/refs/replace"
assert_collector_rejects 'collector dangling source replace symlink'
rm "$TMP/work/.git/refs/replace"

mkdir -p "$TMP/work/.git/info"
printf '%s\n' "$source_head" > "$TMP/work/.git/info/grafts"
assert_collector_rejects 'collector source info/grafts'
rm "$TMP/work/.git/info/grafts"

mkdir -p "$TMP/work/feeds/packages"
git -C "$TMP/work/feeds/packages" init -q
mkdir -p "$TMP/work/feeds/packages/.git/refs/replace"
printf '%s\n' "$source_head" > "$TMP/work/feeds/packages/.git/refs/replace/$source_head"
assert_collector_rejects 'collector loose feed replace ref'
rm -rf "$TMP/work/feeds"

echo 'Git replace/grafts rejection, deterministic KBUILD identity, shared input enumeration, and credential policy: OK'
