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
printf 'safe build log\n' > "$TMP/build.log"

assert_collector_rejects() {
  local label="$1"
  expect_failure "$label" \
    "$ROOT_DIR/scripts/collect-build-evidence.sh" official "$TMP/work" "$TMP/dist" "$TMP/build.log"
}

mkdir -p "$TMP/work/package" "$TMP/work/feeds/packages"
git -C "$TMP/work/feeds/packages" init -q
git -C "$TMP/work/feeds/packages" config user.name tester
git -C "$TMP/work/feeds/packages" config user.email tester@example.invalid
git -C "$TMP/work/feeds/packages" remote add origin https://example.invalid/packages.git
printf 'feed\n' > "$TMP/work/feeds/packages/tracked.txt"
git -C "$TMP/work/feeds/packages" add tracked.txt
git -C "$TMP/work/feeds/packages" commit -qm initial
ln -s ../package "$TMP/work/feeds/base"
feed_head="$(git -C "$TMP/work/feeds/packages" rev-parse HEAD)"
"$ROOT_DIR/scripts/collect-build-evidence.sh" official \
  "$TMP/work" "$TMP/dist" "$TMP/build.log" >/dev/null ||
  fail 'collector rejected the standard feeds/base symlink'
grep -Fqx "feed.packages.commit=$feed_head" "$TMP/dist/EVIDENCE/SOURCE-STATE.txt" ||
  fail 'collector omitted feed commit metadata'
grep -Fqx 'feed.packages.origin=https://example.invalid/packages.git' \
  "$TMP/dist/EVIDENCE/SOURCE-STATE.txt" || fail 'collector omitted feed origin metadata'
grep -Eq '^feed\.packages\.worktree_diff_sha256=[0-9a-f]{64}$' \
  "$TMP/dist/EVIDENCE/SOURCE-STATE.txt" || fail 'collector omitted feed worktree diff metadata'
clean_feed_untracked="$TMP/clean-feed-untracked.list"
git -C "$TMP/work/feeds/packages" ls-files --others -z > "$clean_feed_untracked" ||
  fail 'clean feed untracked enumeration failed'
[[ ! -s "$clean_feed_untracked" ]] || fail 'clean feed fixture unexpectedly has untracked files'
[[ -d "$TMP/dist/EVIDENCE" && -s "$TMP/dist/EVIDENCE/EVIDENCE.sha256" ]] ||
  fail 'clean feed success path did not publish complete evidence'

printf 'ignored.bin\n' > "$TMP/work/feeds/packages/.gitignore"
git -C "$TMP/work/feeds/packages" add .gitignore
git -C "$TMP/work/feeds/packages" commit -qm ignore-rule
printf 'ignored but still untracked\n' > "$TMP/work/feeds/packages/ignored.bin"
assert_collector_rejects 'collector ignored untracked feed file'
[[ ! -e "$TMP/dist/EVIDENCE" ]] ||
  fail 'ignored untracked feed file published final evidence'
rm -f "$TMP/work/feeds/packages/ignored.bin"
git -C "$TMP/work/feeds/packages" reset --hard "$feed_head" >/dev/null

printf 'feed v2\n' > "$TMP/work/feeds/packages/tracked.txt"
git -C "$TMP/work/feeds/packages" add tracked.txt
git -C "$TMP/work/feeds/packages" commit -qm second
feed_next="$(git -C "$TMP/work/feeds/packages" rev-parse HEAD)"
git -C "$TMP/work/feeds/packages" reset --hard "$feed_head" >/dev/null

assert_unsafe_feed_name_rejected() {
  local label="$1"
  local feed_name="$2"

  mkdir -- "$TMP/work/feeds/$feed_name"
  rm -rf "$TMP/dist/EVIDENCE"
  assert_collector_rejects "$label"
  [[ ! -e "$TMP/dist/EVIDENCE" ]] || fail "$label began evidence collection"
  rmdir -- "$TMP/work/feeds/$feed_name"
}

assert_unsafe_feed_name_rejected 'collector newline feed name' $'bad\nfeed'
assert_unsafe_feed_name_rejected 'collector carriage-return feed name' $'bad\rfeed'
assert_unsafe_feed_name_rejected 'collector equals feed name' 'bad=feed'
assert_unsafe_feed_name_rejected 'collector control-character feed name' $'bad\x01feed'
printf -v overlong_feed_name 'f%.0s' {1..129}
assert_unsafe_feed_name_rejected 'collector overlong feed name' "$overlong_feed_name"

ln -s packages "$TMP/work/feeds/linked-feed"
assert_collector_rejects 'collector non-base top-level feed symlink'
rm "$TMP/work/feeds/linked-feed"

rm "$TMP/work/feeds/base"
ln -s ../feeds/../package "$TMP/work/feeds/base"
assert_collector_rejects 'collector noncanonical feeds/base target'
rm "$TMP/work/feeds/base"

newline_package="$TMP/work/package"$'\n'
mkdir "$newline_package"
ln -s $'../package\n' "$TMP/work/feeds/base"
assert_collector_rejects 'collector newline-suffixed feeds/base target'
rm "$TMP/work/feeds/base"
rmdir "$newline_package"

mv "$TMP/work/package" "$TMP/work/package.saved"
ln -s ../package "$TMP/work/feeds/base"
assert_collector_rejects 'collector dangling feeds/base symlink'
rm "$TMP/work/feeds/base"
mv "$TMP/work/package.saved" "$TMP/work/package"

mkdir "$TMP/external-package"
rmdir "$TMP/work/package"
ln -s "$TMP/external-package" "$TMP/work/package"
ln -s ../package "$TMP/work/feeds/base"
assert_collector_rejects 'collector escaping feeds/base symlink'
rm "$TMP/work/feeds/base" "$TMP/work/package"
mkdir "$TMP/work/package"

find_wrapper_dir="$TMP/find-wrapper"
real_find="$(command -v find)"
mkdir "$find_wrapper_dir"
cat > "$find_wrapper_dir/find" <<'EOF_FIND_WRAPPER'
#!/usr/bin/env bash
if [[ "${1:-}" == "${NEXAWRT_TEST_FAIL_FIND_PATH:-}" ]]; then
  exit 73
fi
if [[ -n "${NEXAWRT_TEST_FAIL_EVIDENCE_CWD:-}" &&
      "$(pwd -P)" == "$NEXAWRT_TEST_FAIL_EVIDENCE_CWD" ]]; then
  printf './build.log\0'
  exit 73
fi
if [[ -n "${NEXAWRT_TEST_FAIL_EVIDENCE_PARENT:-}" ]]; then
  current_cwd="$(pwd -P)"
  case "$current_cwd" in
    "$NEXAWRT_TEST_FAIL_EVIDENCE_PARENT"/.EVIDENCE.*)
      printf './build.log\0'
      exit 73
      ;;
  esac
fi
exec "$NEXAWRT_TEST_REAL_FIND" "$@"
EOF_FIND_WRAPPER
chmod +x "$find_wrapper_dir/find"
expect_failure 'collector top-level feed enumeration failure' \
  env PATH="$find_wrapper_dir:$PATH" \
  NEXAWRT_TEST_FAIL_FIND_PATH="$TMP/work/feeds" \
  NEXAWRT_TEST_REAL_FIND="$real_find" \
  "$ROOT_DIR/scripts/collect-build-evidence.sh" official \
  "$TMP/work" "$TMP/dist" "$TMP/build.log"

mkdir -p "$TMP/collector-tmp"
expect_failure 'collector partial evidence enumeration failure' \
  env PATH="$find_wrapper_dir:$PATH" TMPDIR="$TMP/collector-tmp" \
  NEXAWRT_TEST_FAIL_EVIDENCE_PARENT="$(cd "$TMP/dist" && pwd -P)" \
  NEXAWRT_TEST_REAL_FIND="$real_find" \
  "$ROOT_DIR/scripts/collect-build-evidence.sh" official \
  "$TMP/work" "$TMP/dist" "$TMP/build.log"
[[ ! -e "$TMP/dist/EVIDENCE" ]] ||
  fail 'partial evidence enumeration published final evidence'
if compgen -G "$TMP/collector-tmp/nexawrt-*" >/dev/null ||
   compgen -G "$TMP/dist/.nexawrt-evidence-files.*" >/dev/null ||
   compgen -G "$TMP/dist/.EVIDENCE.*" >/dev/null; then
  fail 'collector left temporary files after evidence enumeration failure'
fi

checksum_wrapper_dir="$TMP/checksum-wrapper"
mkdir "$checksum_wrapper_dir"
cat > "$checksum_wrapper_dir/sha256sum" <<'EOF_SHA256SUM_WRAPPER'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == -c ]]; then
  exit 74
fi
if [[ "${NEXAWRT_TEST_REAL_SHA256SUM_IS_SHASUM:-0}" == 1 ]]; then
  exec "$NEXAWRT_TEST_REAL_SHA256SUM" -a 256 "$@"
fi
exec "$NEXAWRT_TEST_REAL_SHA256SUM" "$@"
EOF_SHA256SUM_WRAPPER
cat > "$checksum_wrapper_dir/shasum" <<'EOF_SHASUM_WRAPPER'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == -a && "${2:-}" == 256 && "${3:-}" == -c ]]; then
  exit 74
fi
exec "$NEXAWRT_TEST_REAL_SHASUM" "$@"
EOF_SHASUM_WRAPPER
chmod +x "$checksum_wrapper_dir/sha256sum" "$checksum_wrapper_dir/shasum"
real_sha256sum="$(command -v sha256sum || true)"
real_shasum="$(command -v shasum || true)"
[[ -n "$real_sha256sum" || -n "$real_shasum" ]] || fail 'no checksum tool available for wrapper test'
sha256sum_is_shasum=0
if [[ -z "$real_sha256sum" ]]; then
  real_sha256sum="$real_shasum"
  sha256sum_is_shasum=1
fi
: "${real_shasum:=$real_sha256sum}"
expect_failure 'collector checksum verification failure' \
  env PATH="$checksum_wrapper_dir:$PATH" TMPDIR="$TMP/collector-tmp" \
  NEXAWRT_TEST_REAL_SHA256SUM="$real_sha256sum" \
  NEXAWRT_TEST_REAL_SHA256SUM_IS_SHASUM="$sha256sum_is_shasum" \
  NEXAWRT_TEST_REAL_SHASUM="$real_shasum" \
  "$ROOT_DIR/scripts/collect-build-evidence.sh" official \
  "$TMP/work" "$TMP/dist" "$TMP/build.log"
[[ ! -e "$TMP/dist/EVIDENCE" ]] ||
  fail 'checksum verification failure published final evidence'
if compgen -G "$TMP/collector-tmp/nexawrt-*" >/dev/null ||
   compgen -G "$TMP/dist/.nexawrt-evidence-files.*" >/dev/null ||
   compgen -G "$TMP/dist/.EVIDENCE.*" >/dev/null ||
   compgen -G "$TMP/dist/.EVIDENCE.sha256.*" >/dev/null; then
  fail 'collector left temporary files after checksum verification failure'
fi

git_wrapper_dir="$TMP/git-wrapper"
real_git="$(command -v git)"
mkdir "$git_wrapper_dir"
cat > "$git_wrapper_dir/git" <<'EOF_GIT_WRAPPER'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${NEXAWRT_TEST_MUTATE_FEED:-}" == 1 &&
      ! -e "$NEXAWRT_TEST_MUTATION_MARKER" ]]; then
  case "$NEXAWRT_TEST_MUTATION_ACTION" in
    delete|symlink-git|add-feed)
      if [[ "${1:-}" == -C && "${2:-}" == "$NEXAWRT_TEST_SOURCE_DIR" &&
            "${3:-}" == remote && "${4:-}" == get-url && "${5:-}" == origin ]]; then
        : > "$NEXAWRT_TEST_MUTATION_MARKER"
        case "$NEXAWRT_TEST_MUTATION_ACTION" in
          delete)
            mv -- "$NEXAWRT_TEST_FEED_DIR" "$NEXAWRT_TEST_FEED_BACKUP"
            ;;
          symlink-git)
            mv -- "$NEXAWRT_TEST_FEED_DIR/.git" "$NEXAWRT_TEST_FEED_BACKUP"
            ln -s -- "$NEXAWRT_TEST_FEED_BACKUP" "$NEXAWRT_TEST_FEED_DIR/.git"
            ;;
          add-feed)
            mv -- "$NEXAWRT_TEST_ADDED_FEED_SOURCE" "$NEXAWRT_TEST_ADDED_FEED_TARGET"
            ;;
        esac
      fi
      ;;
    switch-head)
      if [[ "${1:-}" == -C && "${2:-}" == "$NEXAWRT_TEST_FEED_DIR" &&
            "${3:-}" == remote && "${4:-}" == get-url && "${5:-}" == origin ]]; then
        : > "$NEXAWRT_TEST_MUTATION_MARKER"
        "$NEXAWRT_TEST_REAL_GIT" -C "$NEXAWRT_TEST_FEED_DIR" reset --hard "$NEXAWRT_TEST_FEED_NEW_HEAD" >/dev/null
      fi
      ;;
    dirty-after-diff|untracked-after-diff)
      if [[ "${1:-}" == -C && "${2:-}" == "$NEXAWRT_TEST_FEED_DIR" &&
            "${3:-}" == diff ]]; then
        : > "$NEXAWRT_TEST_MUTATION_MARKER.diff-seen"
      elif [[ -e "$NEXAWRT_TEST_MUTATION_MARKER.diff-seen" &&
              "${1:-}" == -C && "${2:-}" == "$NEXAWRT_TEST_FEED_DIR" &&
              "${3:-}" == remote && "${4:-}" == get-url && "${5:-}" == origin ]]; then
        : > "$NEXAWRT_TEST_MUTATION_MARKER"
        case "$NEXAWRT_TEST_MUTATION_ACTION" in
          dirty-after-diff)
            printf 'mutated after initial diff\n' > "$NEXAWRT_TEST_FEED_DIR/tracked.txt"
            ;;
          untracked-after-diff)
            mkdir -p "$NEXAWRT_TEST_FEED_DIR/package"
            printf 'untracked feed package\n' > "$NEXAWRT_TEST_FEED_DIR/package/Makefile"
            ;;
        esac
      fi
      ;;
    *)
      exit 98
      ;;
  esac
fi
exec "$NEXAWRT_TEST_REAL_GIT" "$@"
EOF_GIT_WRAPPER
chmod +x "$git_wrapper_dir/git"

mutation_marker="$TMP/feed-mutation.marker"
deleted_feed_backup="$TMP/packages-feed.saved"
rm -f "$mutation_marker"
expect_failure 'collector feed disappears after validation' \
  env PATH="$git_wrapper_dir:$PATH" \
  NEXAWRT_TEST_MUTATE_FEED=1 \
  NEXAWRT_TEST_MUTATION_ACTION=delete \
  NEXAWRT_TEST_MUTATION_MARKER="$mutation_marker" \
  NEXAWRT_TEST_SOURCE_DIR="$TMP/work" \
  NEXAWRT_TEST_FEED_DIR="$TMP/work/feeds/packages" \
  NEXAWRT_TEST_FEED_BACKUP="$deleted_feed_backup" \
  NEXAWRT_TEST_REAL_GIT="$real_git" \
  "$ROOT_DIR/scripts/collect-build-evidence.sh" official \
  "$TMP/work" "$TMP/dist" "$TMP/build.log"
[[ -d "$deleted_feed_backup/.git" && ! -e "$TMP/work/feeds/packages" ]] ||
  fail 'feed deletion wrapper did not run at the intended collection point'
mv -- "$deleted_feed_backup" "$TMP/work/feeds/packages"

symlinked_git_backup="$TMP/packages-git.saved"
rm -f "$mutation_marker"
expect_failure 'collector feed Git metadata becomes symlink after validation' \
  env PATH="$git_wrapper_dir:$PATH" \
  NEXAWRT_TEST_MUTATE_FEED=1 \
  NEXAWRT_TEST_MUTATION_ACTION=symlink-git \
  NEXAWRT_TEST_MUTATION_MARKER="$mutation_marker" \
  NEXAWRT_TEST_SOURCE_DIR="$TMP/work" \
  NEXAWRT_TEST_FEED_DIR="$TMP/work/feeds/packages" \
  NEXAWRT_TEST_FEED_BACKUP="$symlinked_git_backup" \
  NEXAWRT_TEST_REAL_GIT="$real_git" \
  "$ROOT_DIR/scripts/collect-build-evidence.sh" official \
  "$TMP/work" "$TMP/dist" "$TMP/build.log"
[[ -L "$TMP/work/feeds/packages/.git" && -d "$symlinked_git_backup" ]] ||
  fail 'Git metadata symlink wrapper did not run at the intended collection point'
rm -- "$TMP/work/feeds/packages/.git"
mv -- "$symlinked_git_backup" "$TMP/work/feeds/packages/.git"

rm -f "$mutation_marker"
expect_failure 'collector feed HEAD changes during origin collection' \
  env PATH="$git_wrapper_dir:$PATH" \
  NEXAWRT_TEST_MUTATE_FEED=1 \
  NEXAWRT_TEST_MUTATION_ACTION=switch-head \
  NEXAWRT_TEST_MUTATION_MARKER="$mutation_marker" \
  NEXAWRT_TEST_SOURCE_DIR="$TMP/work" \
  NEXAWRT_TEST_FEED_DIR="$TMP/work/feeds/packages" \
  NEXAWRT_TEST_FEED_NEW_HEAD="$feed_next" \
  NEXAWRT_TEST_REAL_GIT="$real_git" \
  "$ROOT_DIR/scripts/collect-build-evidence.sh" official \
  "$TMP/work" "$TMP/dist" "$TMP/build.log"
[[ "$(git -C "$TMP/work/feeds/packages" rev-parse HEAD)" == "$feed_next" ]] ||
  fail 'feed HEAD switch wrapper did not run at the intended collection point'
if [[ -e "$TMP/dist/EVIDENCE/SOURCE-STATE.txt" ||
      -e "$TMP/dist/EVIDENCE/EVIDENCE.sha256" ]]; then
  fail 'feed HEAD race produced trusted source state or checksum manifest'
fi
git -C "$TMP/work/feeds/packages" reset --hard "$feed_head" >/dev/null

rm -f "$mutation_marker" "$mutation_marker.diff-seen"
expect_failure 'collector feed worktree changes after initial diff' \
  env PATH="$git_wrapper_dir:$PATH" \
  NEXAWRT_TEST_MUTATE_FEED=1 \
  NEXAWRT_TEST_MUTATION_ACTION=dirty-after-diff \
  NEXAWRT_TEST_MUTATION_MARKER="$mutation_marker" \
  NEXAWRT_TEST_FEED_DIR="$TMP/work/feeds/packages" \
  NEXAWRT_TEST_REAL_GIT="$real_git" \
  "$ROOT_DIR/scripts/collect-build-evidence.sh" official \
  "$TMP/work" "$TMP/dist" "$TMP/build.log"
[[ "$(cat "$TMP/work/feeds/packages/tracked.txt")" == 'mutated after initial diff' ]] ||
  fail 'feed worktree dirty wrapper did not run after initial diff'
if [[ -e "$TMP/dist/EVIDENCE/SOURCE-STATE.txt" ||
      -e "$TMP/dist/EVIDENCE/EVIDENCE.sha256" ]]; then
  fail 'feed worktree race produced trusted source state or checksum manifest'
fi
git -C "$TMP/work/feeds/packages" reset --hard "$feed_head" >/dev/null
rm -f "$mutation_marker.diff-seen"

rm -f "$mutation_marker" "$mutation_marker.diff-seen"
rm -rf "$TMP/work/feeds/packages/package"
expect_failure 'collector feed untracked file appears after initial diff' \
  env PATH="$git_wrapper_dir:$PATH" \
  NEXAWRT_TEST_MUTATE_FEED=1 \
  NEXAWRT_TEST_MUTATION_ACTION=untracked-after-diff \
  NEXAWRT_TEST_MUTATION_MARKER="$mutation_marker" \
  NEXAWRT_TEST_FEED_DIR="$TMP/work/feeds/packages" \
  NEXAWRT_TEST_REAL_GIT="$real_git" \
  "$ROOT_DIR/scripts/collect-build-evidence.sh" official \
  "$TMP/work" "$TMP/dist" "$TMP/build.log"
[[ -f "$TMP/work/feeds/packages/package/Makefile" ]] ||
  fail 'feed untracked wrapper did not run after initial diff'
[[ ! -e "$TMP/dist/EVIDENCE" ]] ||
  fail 'feed untracked race published final evidence'
rm -rf "$TMP/work/feeds/packages/package"
rm -f "$mutation_marker.diff-seen"

added_feed_source="$TMP/extra-feed-source"
added_feed_target="$TMP/work/feeds/extra"
mkdir "$added_feed_source"
git -C "$added_feed_source" init -q
git -C "$added_feed_source" config user.name tester
git -C "$added_feed_source" config user.email tester@example.invalid
git -C "$added_feed_source" remote add origin https://example.invalid/extra.git
printf 'extra feed\n' > "$added_feed_source/tracked.txt"
git -C "$added_feed_source" add tracked.txt
git -C "$added_feed_source" commit -qm initial
rm -f "$mutation_marker"
expect_failure 'collector feed appears after validation' \
  env PATH="$git_wrapper_dir:$PATH" \
  NEXAWRT_TEST_MUTATE_FEED=1 \
  NEXAWRT_TEST_MUTATION_ACTION=add-feed \
  NEXAWRT_TEST_MUTATION_MARKER="$mutation_marker" \
  NEXAWRT_TEST_SOURCE_DIR="$TMP/work" \
  NEXAWRT_TEST_ADDED_FEED_SOURCE="$added_feed_source" \
  NEXAWRT_TEST_ADDED_FEED_TARGET="$added_feed_target" \
  NEXAWRT_TEST_REAL_GIT="$real_git" \
  "$ROOT_DIR/scripts/collect-build-evidence.sh" official \
  "$TMP/work" "$TMP/dist" "$TMP/build.log"
[[ -d "$added_feed_target/.git" ]] ||
  fail 'feed addition wrapper did not run after initial validation'
if [[ -e "$TMP/dist/EVIDENCE/SOURCE-STATE.txt" ||
      -e "$TMP/dist/EVIDENCE/EVIDENCE.sha256" ]]; then
  fail 'feed addition race produced trusted source state or checksum manifest'
fi
rm -rf "$added_feed_target"

mkdir "$TMP/work/feeds/base"
assert_collector_rejects 'collector regular feeds/base directory'
rmdir "$TMP/work/feeds/base"
printf 'not a symlink\n' > "$TMP/work/feeds/base"
assert_collector_rejects 'collector regular feeds/base file'
rm "$TMP/work/feeds/base"
ln -s ../package "$TMP/work/feeds/base"

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

mkdir -p "$TMP/work/feeds/packages/.git/refs/replace"
printf '%s\n' "$feed_head" \
  > "$TMP/work/feeds/packages/.git/refs/replace/$feed_head"
assert_collector_rejects 'collector loose feed replace ref'
rm -rf "$TMP/work/feeds"

echo 'Git replace/grafts rejection, strict feeds/base handling, deterministic KBUILD identity, shared input enumeration, and credential policy: OK'
