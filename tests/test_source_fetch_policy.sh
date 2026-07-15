#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nexawrt-source-fetch-policy.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null

REAL_GIT="$(command -v git)"
FIXTURE_REPO="$TMP_DIR/canonical-source"
POLICY_REPO="$TMP_DIR/policy-repo"
WRAPPER_DIR="$TMP_DIR/wrappers"

expect_failure() {
  local description="$1"
  local expected="$2"
  shift 2
  local output="$TMP_DIR/failure-output"

  if "$@" >"$output" 2>&1; then
    echo "$description unexpectedly passed" >&2
    exit 1
  fi
  grep -Fq "$expected" "$output" || {
    echo "$description failed for an unexpected reason" >&2
    cat "$output" >&2
    exit 1
  }
}

mkdir -p "$FIXTURE_REPO"
"$REAL_GIT" -C "$FIXTURE_REPO" init -q
"$REAL_GIT" -C "$FIXTURE_REPO" config user.name 'NexaWrt source fixture'
"$REAL_GIT" -C "$FIXTURE_REPO" config user.email 'fixture@example.invalid'
printf 'base\n' > "$FIXTURE_REPO/tracked.txt"
printf '/version\n/overlay/\n/*.patch\n' > "$FIXTURE_REPO/.gitignore"
: > "$FIXTURE_REPO/feeds.conf.default"
"$REAL_GIT" -C "$FIXTURE_REPO" add tracked.txt feeds.conf.default .gitignore
"$REAL_GIT" -C "$FIXTURE_REPO" commit -qm 'fixture source'
SOURCE_COMMIT="$("$REAL_GIT" -C "$FIXTURE_REPO" rev-parse HEAD)"

mkdir -p \
  "$POLICY_REPO/scripts" \
  "$POLICY_REPO/manifests" \
  "$POLICY_REPO/configs" \
  "$POLICY_REPO/files" \
  "$POLICY_REPO/patches"
cp "$ROOT_DIR/scripts/prepare.sh" "$POLICY_REPO/scripts/prepare.sh"
cp "$ROOT_DIR/scripts/sanitize-git-environment.sh" "$POLICY_REPO/scripts/sanitize-git-environment.sh"
cp "$ROOT_DIR/scripts/git-metadata-policy.sh" "$POLICY_REPO/scripts/git-metadata-policy.sh"
cp "$ROOT_DIR/scripts/lock-file-policy.sh" "$POLICY_REPO/scripts/lock-file-policy.sh"
cat > "$POLICY_REPO/manifests/upstream.lock" <<LOCK
OPENWRT_REPO="https://example.invalid/openwrt.git"
OPENWRT_TAG="fixture"
OPENWRT_COMMIT="$SOURCE_COMMIT"
LAYOUT_ID="fixture-layout"
ROOTFS_MTD_OFFSET_HEX="0x00000001"
ROOTFS_MTD_SIZE_HEX="0x00000002"
ROOTFS_MTD_ERASE_SIZE_HEX="0x00000001"
LOCK
: > "$POLICY_REPO/manifests/feeds.lock"
printf 'CONFIG_FIXTURE=y\n' > "$POLICY_REPO/configs/ax9000-single-ubi.config"
printf 'prepared\n' > "$FIXTURE_REPO/tracked.txt"
"$REAL_GIT" -C "$FIXTURE_REPO" diff --binary --no-ext-diff HEAD -- tracked.txt \
  > "$POLICY_REPO/patches/001-fixture.patch"
"$REAL_GIT" -C "$FIXTURE_REPO" reset -q --hard HEAD
cat > "$POLICY_REPO/scripts/validate.sh" <<'VALIDATE'
#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT_DIR/manifests/upstream.lock"
SOURCE_DIR=""
while (($#)); do
  case "$1" in
    --source) SOURCE_DIR="${2:?missing source path}"; shift ;;
    *) echo "unexpected validate argument: $1" >&2; exit 2 ;;
  esac
  shift
done
[[ -n "$SOURCE_DIR" ]]
[[ "$(git -C "$SOURCE_DIR" rev-parse --verify HEAD)" == "$OPENWRT_COMMIT" ]]
[[ "$(git -C "$SOURCE_DIR" config --get-all remote.origin.url)" == "${OPENWRT_REPO_OVERRIDE:-$OPENWRT_REPO}" ]]
! git -C "$SOURCE_DIR" config --get-all remote.origin.pushurl >/dev/null 2>&1
[[ "$(cat "$SOURCE_DIR/tracked.txt")" == prepared ]]
expected_revision="r0-${OPENWRT_COMMIT:0:8}"
[[ -f "$SOURCE_DIR/version" && ! -L "$SOURCE_DIR/version" ]]
cmp -s -- "$SOURCE_DIR/version" <(printf '%s\n' "$expected_revision")
VALIDATE
chmod +x "$POLICY_REPO/scripts/prepare.sh" "$POLICY_REPO/scripts/validate.sh"

mkdir -p "$WRAPPER_DIR"
cat > "$WRAPPER_DIR/git" <<'GIT_WRAPPER'
#!/usr/bin/env bash
set -euo pipefail
[[ "${GIT_NO_REPLACE_OBJECTS:-}" == 1 ]] || {
  echo 'prepare did not globally export GIT_NO_REPLACE_OBJECTS=1' >&2
  exit 97
}
is_fetch=0
for argument in "$@"; do
  if [[ "$argument" == fetch ]]; then
    is_fetch=1
    break
  fi
done
if ((is_fetch)); then
  printf 'fetch %q ' "$@" >> "${FETCH_LOG:?}"
  printf '\n' >> "$FETCH_LOG"
  if [[ "${BLOCK_FETCH:-0}" == 1 ]]; then
    echo 'fixture blocked unexpected fetch' >&2
    exit 86
  fi
fi
exec "${REAL_GIT:?}" "$@"
GIT_WRAPPER
cat > "$WRAPPER_DIR/sleep" <<'SLEEP_WRAPPER'
#!/usr/bin/env bash
exit 0
SLEEP_WRAPPER
chmod +x "$WRAPPER_DIR/git" "$WRAPPER_DIR/sleep"

run_prepare() {
  local work_dir="$1"
  local fetch_log="$2"
  local block_fetch="$3"
  env \
    PATH="$WRAPPER_DIR:$PATH" \
    REAL_GIT="$REAL_GIT" \
    FETCH_LOG="$fetch_log" \
    BLOCK_FETCH="$block_fetch" \
    NEXAWRT_FLAVOR=official \
    OPENWRT_REPO_OVERRIDE="$FIXTURE_REPO" \
    WORK_DIR="$work_dir" \
    "$POLICY_REPO/scripts/prepare.sh" --no-feeds
}

# A canonical checkout with the complete pinned commit may be reused without any
# fetch. A dirty, incorrect HEAD must still be replaced by the exact lock before
# the patch is applied.
REUSE_WORK="$TMP_DIR/reuse-work"
"$REAL_GIT" clone -q "$FIXTURE_REPO" "$REUSE_WORK"
"$REAL_GIT" -C "$REUSE_WORK" config user.name 'NexaWrt source fixture'
"$REAL_GIT" -C "$REUSE_WORK" config user.email 'fixture@example.invalid'
printf 'wrong-head\n' > "$REUSE_WORK/tracked.txt"
"$REAL_GIT" -C "$REUSE_WORK" commit -qam 'wrong head'
printf 'stale\n' > "$REUSE_WORK/stale-untracked.txt"
mkdir -p "$REUSE_WORK/overlay"
printf 'hostile ignored package input\n' > "$REUSE_WORK/overlay/hostile.txt"
printf 'hostile ignored patch input\n' > "$REUSE_WORK/hostile.patch"
printf 'outside-must-not-change\n' > "$TMP_DIR/stale-version-target"
ln -s "$TMP_DIR/stale-version-target" "$REUSE_WORK/version"
REUSE_FETCH_LOG="$TMP_DIR/reuse-fetch.log"
run_prepare "$REUSE_WORK" "$REUSE_FETCH_LOG" 1 >/dev/null
[[ ! -s "$REUSE_FETCH_LOG" ]] || {
  echo 'complete canonical source checkout unexpectedly fetched' >&2
  cat "$REUSE_FETCH_LOG" >&2
  exit 1
}
[[ "$("$REAL_GIT" -C "$REUSE_WORK" rev-parse HEAD)" == "$SOURCE_COMMIT" ]]
[[ "$(cat "$REUSE_WORK/tracked.txt")" == prepared ]]
[[ ! -e "$REUSE_WORK/stale-untracked.txt" ]]
[[ ! -e "$REUSE_WORK/overlay" ]]
[[ ! -e "$REUSE_WORK/hostile.patch" ]]
[[ "$(cat "$TMP_DIR/stale-version-target")" == outside-must-not-change ]]
[[ -f "$REUSE_WORK/version" && ! -L "$REUSE_WORK/version" ]]
cmp -s -- "$REUSE_WORK/version" <(printf 'r0-%s\n' "${SOURCE_COMMIT:0:8}")
echo 'complete canonical source offline reuse replaces ignored stale revision: OK'


assert_source_history_override_rejected() {
  local description="$1"
  local expected="$2"
  local work_dir="$3"
  local fetch_log="$TMP_DIR/${description// /-}-fetch.log"

  expect_failure "$description" "$expected" \
    run_prepare "$work_dir" "$fetch_log" 1
  [[ ! -s "$fetch_log" ]] || {
    echo "$description reached the fetch path" >&2
    exit 1
  }
}


LOCAL_CONFIG_WORK="$TMP_DIR/local-config-work"
"$REAL_GIT" clone -q "$FIXTURE_REPO" "$LOCAL_CONFIG_WORK"
"$REAL_GIT" -C "$LOCAL_CONFIG_WORK" config filter.evil.smudge 'cat'
assert_source_history_override_rejected 'source local filter config' \
  'forbidden Git local config: filter.evil.smudge' "$LOCAL_CONFIG_WORK"
echo 'source local filter config rejection: OK'

INFO_ATTRIBUTES_WORK="$TMP_DIR/info-attributes-work"
"$REAL_GIT" clone -q "$FIXTURE_REPO" "$INFO_ATTRIBUTES_WORK"
printf '* filter=evil\n' > "$INFO_ATTRIBUTES_WORK/.git/info/attributes"
assert_source_history_override_rejected 'source info attributes' \
  'forbidden Git metadata' "$INFO_ATTRIBUTES_WORK"
echo 'source info/attributes rejection: OK'

ACTIVE_HOOK_WORK="$TMP_DIR/active-hook-work"
"$REAL_GIT" clone -q "$FIXTURE_REPO" "$ACTIVE_HOOK_WORK"
printf '#!/bin/sh\nexit 1\n' > "$ACTIVE_HOOK_WORK/.git/hooks/post-checkout"
chmod +x "$ACTIVE_HOOK_WORK/.git/hooks/post-checkout"
assert_source_history_override_rejected 'source active checkout hook' \
  'active or unexpected Git hook' "$ACTIVE_HOOK_WORK"
echo 'source active hook rejection: OK'

LOCK_SYNTAX_POLICY="$TMP_DIR/lock-syntax-policy"
cp -R "$POLICY_REPO" "$LOCK_SYNTAX_POLICY"
printf 'touch %q\n' "$TMP_DIR/lock-command-executed" >> "$LOCK_SYNTAX_POLICY/manifests/upstream.lock"
expect_failure 'executable lock syntax' 'non-declarative syntax' \
  env NEXAWRT_FLAVOR=official OPENWRT_REPO_OVERRIDE="$FIXTURE_REPO" \
    WORK_DIR="$TMP_DIR/lock-syntax-work" "$LOCK_SYNTAX_POLICY/scripts/prepare.sh" --no-feeds
[[ ! -e "$TMP_DIR/lock-command-executed" ]]
echo 'non-declarative lock syntax rejection before source: OK'

LOOSE_REPLACE_WORK="$TMP_DIR/loose-replace-work"
"$REAL_GIT" clone -q "$FIXTURE_REPO" "$LOOSE_REPLACE_WORK"
mkdir -p "$LOOSE_REPLACE_WORK/.git/refs/replace"
printf '%s\n' "$SOURCE_COMMIT" > "$LOOSE_REPLACE_WORK/.git/refs/replace/$SOURCE_COMMIT"
assert_source_history_override_rejected 'loose source replace ref' \
  'forbidden Git replace/grafts metadata' "$LOOSE_REPLACE_WORK"
echo 'loose source replace ref rejection: OK'

PACKED_REPLACE_WORK="$TMP_DIR/packed-replace-work"
"$REAL_GIT" clone -q "$FIXTURE_REPO" "$PACKED_REPLACE_WORK"
"$REAL_GIT" -C "$PACKED_REPLACE_WORK" pack-refs --all
printf '%s refs/replace/%s\n' "$SOURCE_COMMIT" "$SOURCE_COMMIT" \
  >> "$PACKED_REPLACE_WORK/.git/packed-refs"
assert_source_history_override_rejected 'packed source replace ref' \
  'forbidden packed Git replace refs' "$PACKED_REPLACE_WORK"
echo 'packed source replace ref rejection: OK'

SYMLINK_REPLACE_WORK="$TMP_DIR/symlink-replace-work"
"$REAL_GIT" clone -q "$FIXTURE_REPO" "$SYMLINK_REPLACE_WORK"
ln -s "$TMP_DIR/missing-replace-target" "$SYMLINK_REPLACE_WORK/.git/refs/replace"
assert_source_history_override_rejected 'dangling source replace symlink' \
  'forbidden Git replace/grafts metadata' "$SYMLINK_REPLACE_WORK"
echo 'dangling source replace symlink rejection: OK'

GRAFTS_WORK="$TMP_DIR/grafts-work"
"$REAL_GIT" clone -q "$FIXTURE_REPO" "$GRAFTS_WORK"
printf '%s\n' "$SOURCE_COMMIT" > "$GRAFTS_WORK/.git/info/grafts"
assert_source_history_override_rejected 'source info grafts' \
  'forbidden Git replace/grafts metadata' "$GRAFTS_WORK"
echo 'source info/grafts rejection: OK'

# Even with the exact object present, more than the one canonical origin URL is
# rejected before any fetch or checkout can occur.
WRONG_ORIGIN_WORK="$TMP_DIR/wrong-origin-work"
"$REAL_GIT" clone -q "$FIXTURE_REPO" "$WRONG_ORIGIN_WORK"
"$REAL_GIT" -C "$WRONG_ORIGIN_WORK" remote set-url --add origin "$TMP_DIR/not-canonical"
WRONG_ORIGIN_FETCH_LOG="$TMP_DIR/wrong-origin-fetch.log"
expect_failure 'wrong origin source checkout' 'Refusing unexpected OpenWrt remote:' \
  run_prepare "$WRONG_ORIGIN_WORK" "$WRONG_ORIGIN_FETCH_LOG" 1
[[ ! -s "$WRONG_ORIGIN_FETCH_LOG" ]] || {
  echo 'wrong origin reached the fetch path' >&2
  exit 1
}
echo 'wrong source origin rejection: OK'

# A canonical fetch URL does not make a repository canonical when any pushurl
# exists. Test both one and multiple raw push destinations because `remote
# get-url --all origin` does not expose either form.
SINGLE_PUSHURL_WORK="$TMP_DIR/single-pushurl-work"
"$REAL_GIT" clone -q "$FIXTURE_REPO" "$SINGLE_PUSHURL_WORK"
"$REAL_GIT" -C "$SINGLE_PUSHURL_WORK" config --add \
  remote.origin.pushurl "$TMP_DIR/not-canonical-push"
SINGLE_PUSHURL_FETCH_LOG="$TMP_DIR/single-pushurl-fetch.log"
expect_failure 'single source pushurl' 'Refusing unexpected OpenWrt remote:' \
  run_prepare "$SINGLE_PUSHURL_WORK" "$SINGLE_PUSHURL_FETCH_LOG" 1
[[ ! -s "$SINGLE_PUSHURL_FETCH_LOG" ]] || {
  echo 'single source pushurl reached the fetch path' >&2
  exit 1
}
echo 'single source pushurl rejection: OK'

MULTIPLE_PUSHURL_WORK="$TMP_DIR/multiple-pushurl-work"
"$REAL_GIT" clone -q "$FIXTURE_REPO" "$MULTIPLE_PUSHURL_WORK"
"$REAL_GIT" -C "$MULTIPLE_PUSHURL_WORK" config --add \
  remote.origin.pushurl "$TMP_DIR/not-canonical-push-one"
"$REAL_GIT" -C "$MULTIPLE_PUSHURL_WORK" config --add \
  remote.origin.pushurl "$TMP_DIR/not-canonical-push-two"
MULTIPLE_PUSHURL_FETCH_LOG="$TMP_DIR/multiple-pushurl-fetch.log"
expect_failure 'multiple source pushurls' 'Refusing unexpected OpenWrt remote:' \
  run_prepare "$MULTIPLE_PUSHURL_WORK" "$MULTIPLE_PUSHURL_FETCH_LOG" 1
[[ ! -s "$MULTIPLE_PUSHURL_FETCH_LOG" ]] || {
  echo 'multiple source pushurls reached the fetch path' >&2
  exit 1
}
echo 'multiple source pushurl rejection: OK'

# A repository whose HEAD is unrelated and which lacks the pinned object must use
# the existing exact-commit fetch path. The local canonical fixture makes this a
# controlled, network-free test of the fetch decision.
MISSING_WORK="$TMP_DIR/missing-work"
mkdir -p "$MISSING_WORK"
"$REAL_GIT" -C "$MISSING_WORK" init -q
"$REAL_GIT" -C "$MISSING_WORK" remote add origin "$FIXTURE_REPO"
printf 'unrelated\n' > "$MISSING_WORK/unrelated.txt"
"$REAL_GIT" -C "$MISSING_WORK" config user.name 'NexaWrt source fixture'
"$REAL_GIT" -C "$MISSING_WORK" config user.email 'fixture@example.invalid'
"$REAL_GIT" -C "$MISSING_WORK" add unrelated.txt
"$REAL_GIT" -C "$MISSING_WORK" commit -qm 'unrelated head'
MISSING_FETCH_LOG="$TMP_DIR/missing-fetch.log"
run_prepare "$MISSING_WORK" "$MISSING_FETCH_LOG" 0 >/dev/null
[[ "$(grep -c '^fetch ' "$MISSING_FETCH_LOG")" == 1 ]]
grep -Fq -- '--depth' "$MISSING_FETCH_LOG"
grep -Fq -- "$SOURCE_COMMIT" "$MISSING_FETCH_LOG"
[[ "$("$REAL_GIT" -C "$MISSING_WORK" rev-parse HEAD)" == "$SOURCE_COMMIT" ]]
[[ "$(cat "$MISSING_WORK/tracked.txt")" == prepared ]]
echo 'absent source commit controlled fetch: OK'

# Possessing only the exact commit object is insufficient when its checkout tree
# is incomplete. Copy the commit and root tree objects but omit their blobs; the
# policy must attempt the controlled fetch rather than claim offline reuse.
INCOMPLETE_WORK="$TMP_DIR/incomplete-work"
mkdir -p "$INCOMPLETE_WORK"
"$REAL_GIT" -C "$INCOMPLETE_WORK" init -q
"$REAL_GIT" -C "$INCOMPLETE_WORK" remote add origin "$FIXTURE_REPO"
ROOT_TREE="$("$REAL_GIT" -C "$FIXTURE_REPO" rev-parse "$SOURCE_COMMIT^{tree}")"
[[ "$("$REAL_GIT" -C "$FIXTURE_REPO" cat-file commit "$SOURCE_COMMIT" | \
  "$REAL_GIT" -C "$INCOMPLETE_WORK" hash-object -t commit -w --stdin)" == "$SOURCE_COMMIT" ]]
[[ "$("$REAL_GIT" -C "$FIXTURE_REPO" cat-file tree "$ROOT_TREE" | \
  "$REAL_GIT" -C "$INCOMPLETE_WORK" hash-object -t tree -w --stdin)" == "$ROOT_TREE" ]]
[[ "$("$REAL_GIT" -C "$INCOMPLETE_WORK" cat-file -t "$SOURCE_COMMIT")" == commit ]]
INCOMPLETE_FETCH_LOG="$TMP_DIR/incomplete-fetch.log"
expect_failure 'incomplete source commit closure' 'Unable to fetch pinned official source' \
  run_prepare "$INCOMPLETE_WORK" "$INCOMPLETE_FETCH_LOG" 1
[[ "$(grep -c '^fetch ' "$INCOMPLETE_FETCH_LOG")" == 3 ]]
echo 'incomplete source commit closure rejection: OK'

# An object with the locked name must be an actual commit. A local blob cannot
# impersonate SOURCE_COMMIT and therefore falls through to the retrying fetch
# path, which is blocked here to keep the test offline.
NON_COMMIT_WORK="$TMP_DIR/non-commit-work"
mkdir -p "$NON_COMMIT_WORK"
"$REAL_GIT" -C "$NON_COMMIT_WORK" init -q
"$REAL_GIT" -C "$NON_COMMIT_WORK" remote add origin "$FIXTURE_REPO"
NON_COMMIT_OBJECT="$(printf 'not a commit\n' | "$REAL_GIT" -C "$NON_COMMIT_WORK" hash-object -w --stdin)"
NON_COMMIT_POLICY="$TMP_DIR/non-commit-policy"
cp -R "$POLICY_REPO" "$NON_COMMIT_POLICY"
sed "s/^OPENWRT_COMMIT=.*/OPENWRT_COMMIT=\"$NON_COMMIT_OBJECT\"/" \
  "$NON_COMMIT_POLICY/manifests/upstream.lock" \
  > "$NON_COMMIT_POLICY/manifests/upstream.lock.tmp"
mv "$NON_COMMIT_POLICY/manifests/upstream.lock.tmp" \
  "$NON_COMMIT_POLICY/manifests/upstream.lock"
NON_COMMIT_FETCH_LOG="$TMP_DIR/non-commit-fetch.log"
expect_failure 'non-commit source object' 'Unable to fetch pinned official source' \
  env \
    PATH="$WRAPPER_DIR:$PATH" \
    REAL_GIT="$REAL_GIT" \
    FETCH_LOG="$NON_COMMIT_FETCH_LOG" \
    BLOCK_FETCH=1 \
    NEXAWRT_FLAVOR=official \
    OPENWRT_REPO_OVERRIDE="$FIXTURE_REPO" \
    WORK_DIR="$NON_COMMIT_WORK" \
    "$NON_COMMIT_POLICY/scripts/prepare.sh" --no-feeds
[[ "$(grep -c '^fetch ' "$NON_COMMIT_FETCH_LOG")" == 3 ]]
echo 'non-commit source object rejection: OK'

echo 'source fetch policy tests: OK'
