#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nexawrt-feed-reuse-policy.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null

REAL_GIT="$(command -v git)"
SOURCE_REPO="$TMP_DIR/canonical-source"
FEED_REPO="$TMP_DIR/canonical-feed"
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

mkdir -p "$SOURCE_REPO/scripts" "$SOURCE_REPO/package"
"$REAL_GIT" -C "$SOURCE_REPO" init -q
"$REAL_GIT" -C "$SOURCE_REPO" config user.name 'NexaWrt feed reuse fixture'
"$REAL_GIT" -C "$SOURCE_REPO" config user.email 'fixture@example.invalid'
cat > "$SOURCE_REPO/.gitignore" <<'IGNORE'
/.config
/.nexawrt-feeds-state
/feeds/
/files/
/package/feeds/
IGNORE
cat > "$SOURCE_REPO/feeds.conf.default" <<FEEDS
src-git packages $FEED_REPO
FEEDS
cat > "$SOURCE_REPO/scripts/feeds" <<'FEEDS_HELPER'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${FEEDS_HELPER_LOG:?}"
echo 'fixture feeds helper blocked rebuild path' >&2
exit 88
FEEDS_HELPER
chmod +x "$SOURCE_REPO/scripts/feeds"
cat > "$SOURCE_REPO/Makefile" <<'MAKEFILE'
defconfig:
	@grep -qx 'CONFIG_FIXTURE=y' .config
	@grep -qx 'CONFIG_DEFCONFIG_DONE=y' .config || printf 'CONFIG_DEFCONFIG_DONE=y\n' >> .config
	@rm -rf feeds/base feeds/packages.tmp feeds/packages.index feeds/packages.targetindex
	@mkdir -p feeds/packages.tmp
	@printf 'index\n' > feeds/packages.tmp/.packageinfo
	@printf 'target\n' > feeds/packages.tmp/.targetinfo
	@ln -s ../package feeds/base
	@ln -s packages.tmp/.packageinfo feeds/packages.index
	@ln -s packages.tmp/.targetinfo feeds/packages.targetindex
MAKEFILE
printf 'base\n' > "$SOURCE_REPO/tracked.txt"
"$REAL_GIT" -C "$SOURCE_REPO" add .
"$REAL_GIT" -C "$SOURCE_REPO" commit -qm 'fixture source'
SOURCE_COMMIT="$("$REAL_GIT" -C "$SOURCE_REPO" rev-parse HEAD)"

mkdir -p "$FEED_REPO/pkg"
"$REAL_GIT" -C "$FEED_REPO" init -q
"$REAL_GIT" -C "$FEED_REPO" config user.name 'NexaWrt feed reuse fixture'
"$REAL_GIT" -C "$FEED_REPO" config user.email 'fixture@example.invalid'
printf 'fixture package\n' > "$FEED_REPO/pkg/Makefile"
"$REAL_GIT" -C "$FEED_REPO" add pkg/Makefile
"$REAL_GIT" -C "$FEED_REPO" commit -qm 'fixture feed'
FEED_COMMIT="$("$REAL_GIT" -C "$FEED_REPO" rev-parse HEAD)"

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
cat > "$POLICY_REPO/manifests/feeds.lock" <<LOCK
packages $FEED_REPO $FEED_COMMIT
LOCK
printf 'CONFIG_FIXTURE=y\n' > "$POLICY_REPO/configs/ax9000-single-ubi.config"
printf 'prepared\n' > "$SOURCE_REPO/tracked.txt"
"$REAL_GIT" -C "$SOURCE_REPO" diff --binary --no-ext-diff HEAD -- tracked.txt \
  > "$POLICY_REPO/patches/001-fixture.patch"
"$REAL_GIT" -C "$SOURCE_REPO" reset -q --hard HEAD
cat > "$POLICY_REPO/scripts/validate.sh" <<'VALIDATE'
#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT_DIR/manifests/upstream.lock"
read -r FEED_NAME FEED_REPO FEED_COMMIT < "$ROOT_DIR/manifests/feeds.lock"
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
grep -qx "src-git $FEED_NAME $FEED_REPO^$FEED_COMMIT" "$SOURCE_DIR/feeds.conf.default"
grep -qx 'CONFIG_FIXTURE=y' "$SOURCE_DIR/.config"
grep -qx 'CONFIG_DEFCONFIG_DONE=y' "$SOURCE_DIR/.config"
[[ "$(git -C "$SOURCE_DIR/feeds/$FEED_NAME" rev-parse --verify HEAD)" == "$FEED_COMMIT" ]]
[[ "$(git -C "$SOURCE_DIR/feeds/$FEED_NAME" config --get-all remote.origin.url)" == "$FEED_REPO" ]]
! git -C "$SOURCE_DIR/feeds/$FEED_NAME" config --get-all \
  remote.origin.pushurl >/dev/null 2>&1
[[ -L "$SOURCE_DIR/package/feeds/$FEED_NAME/pkg" ]]
feed_root="$(cd -P "$SOURCE_DIR/feeds/$FEED_NAME" && pwd -P)"
resolved="$(cd -P "$SOURCE_DIR/package/feeds/$FEED_NAME/pkg" && pwd -P)"
case "$resolved" in "$feed_root"/*) ;; *) exit 1 ;; esac
[[ "$(cat "$SOURCE_DIR/.nexawrt-feeds-state")" == $'version=1\nflavor=official\nstate=feeds-installed' ]]
[[ ! -e "$SOURCE_DIR/feeds/base" && ! -L "$SOURCE_DIR/feeds/base" ]]
[[ ! -e "$SOURCE_DIR/feeds/packages.index" && ! -L "$SOURCE_DIR/feeds/packages.index" ]]
[[ ! -e "$SOURCE_DIR/feeds/packages.targetindex" && ! -L "$SOURCE_DIR/feeds/packages.targetindex" ]]
[[ ! -e "$SOURCE_DIR/feeds/packages.tmp" ]]
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

create_prepared_work() {
  local work_dir="$1"

  "$REAL_GIT" clone -q "$SOURCE_REPO" "$work_dir"
  mkdir -p "$work_dir/feeds" "$work_dir/package/feeds/packages"
  "$REAL_GIT" clone -q "$FEED_REPO" "$work_dir/feeds/packages"
  ln -s ../../../feeds/packages/pkg "$work_dir/package/feeds/packages/pkg"
  printf 'version=1\nflavor=official\nstate=feeds-installed\n' \
    > "$work_dir/.nexawrt-feeds-state"
}

run_prepare() {
  local work_dir="$1"
  local fetch_log="$2"
  local helper_log="$3"

  env \
    PATH="$WRAPPER_DIR:$PATH" \
    REAL_GIT="$REAL_GIT" \
    FETCH_LOG="$fetch_log" \
    BLOCK_FETCH=1 \
    FEEDS_HELPER_LOG="$helper_log" \
    ALLOW_UNSUPPORTED_HOST=1 \
    NEXAWRT_FLAVOR=official \
    OPENWRT_REPO_OVERRIDE="$SOURCE_REPO" \
    WORK_DIR="$work_dir" \
    "$POLICY_REPO/scripts/prepare.sh"
}

expect_rebuild_attempt() {
  local description="$1"
  local work_dir="$2"
  local fetch_log="$TMP_DIR/${description// /-}-fetch.log"
  local helper_log="$TMP_DIR/${description// /-}-helper.log"

  expect_failure "$description" 'Unable to update pinned feed packages' \
    run_prepare "$work_dir" "$fetch_log" "$helper_log"
  [[ -s "$fetch_log" ]] || {
    echo "$description did not enter the controlled fetch fallback" >&2
    exit 1
  }
  [[ -s "$helper_log" ]] || {
    echo "$description did not enter the feeds update path" >&2
    exit 1
  }
}

REUSE_WORK="$TMP_DIR/reuse-work"
create_prepared_work "$REUSE_WORK"
REUSE_FETCH_LOG="$TMP_DIR/reuse-fetch.log"
REUSE_HELPER_LOG="$TMP_DIR/reuse-helper.log"
run_prepare "$REUSE_WORK" "$REUSE_FETCH_LOG" "$REUSE_HELPER_LOG" >/dev/null
[[ ! -s "$REUSE_FETCH_LOG" ]] || {
  echo 'verified feed state unexpectedly fetched' >&2
  cat "$REUSE_FETCH_LOG" >&2
  exit 1
}
[[ ! -s "$REUSE_HELPER_LOG" ]] || {
  echo 'verified feed state unexpectedly ran scripts/feeds' >&2
  cat "$REUSE_HELPER_LOG" >&2
  exit 1
}
echo 'fully verified installed feed state offline reuse: OK'

VALIDATE_POLICY_REPO="$TMP_DIR/validate-policy-repo"
mkdir -p "$VALIDATE_POLICY_REPO/scripts" "$VALIDATE_POLICY_REPO/manifests"
cp "$ROOT_DIR/scripts/validate.sh" "$VALIDATE_POLICY_REPO/scripts/validate.sh"
cp "$ROOT_DIR/scripts/sanitize-git-environment.sh" "$VALIDATE_POLICY_REPO/scripts/sanitize-git-environment.sh"
cp "$ROOT_DIR/scripts/git-metadata-policy.sh" "$VALIDATE_POLICY_REPO/scripts/git-metadata-policy.sh"
cp "$ROOT_DIR/scripts/lock-file-policy.sh" "$VALIDATE_POLICY_REPO/scripts/lock-file-policy.sh"
cp "$ROOT_DIR/manifests/upstream.lock" "$VALIDATE_POLICY_REPO/manifests/upstream.lock"
printf 'packages %s %s\n' "$FEED_REPO" "$FEED_COMMIT" \
  > "$VALIDATE_POLICY_REPO/manifests/feeds.lock"
chmod +x "$VALIDATE_POLICY_REPO/scripts/validate.sh"
NEXAWRT_FLAVOR=official "$VALIDATE_POLICY_REPO/scripts/validate.sh" \
  --source "$REUSE_WORK" --feed-policy-only >/dev/null
mkdir -p "$REUSE_WORK/feeds/packages/.git/refs/replace"
printf '%s\n' "$FEED_COMMIT" \
  > "$REUSE_WORK/feeds/packages/.git/refs/replace/$FEED_COMMIT"
expect_failure 'validate loose feed replace ref' \
  'forbidden Git replace/grafts metadata' \
  env NEXAWRT_FLAVOR=official "$VALIDATE_POLICY_REPO/scripts/validate.sh" \
    --source "$REUSE_WORK" --feed-policy-only
rm -rf "$REUSE_WORK/feeds/packages/.git/refs/replace"
echo 'validate feed replace ref rejection: OK'


expect_history_override_rejection() {
  local description="$1"
  local expected="$2"
  local work_dir="$3"
  local fetch_log="$TMP_DIR/${description// /-}-fetch.log"
  local helper_log="$TMP_DIR/${description// /-}-helper.log"

  expect_failure "$description" "$expected" \
    run_prepare "$work_dir" "$fetch_log" "$helper_log"
  [[ ! -s "$fetch_log" ]] || {
    echo "$description reached a fetch path" >&2
    exit 1
  }
  [[ ! -s "$helper_log" ]] || {
    echo "$description reached the feeds helper" >&2
    exit 1
  }
}

LOOSE_REPLACE_WORK="$TMP_DIR/loose-feed-replace-work"
create_prepared_work "$LOOSE_REPLACE_WORK"
mkdir -p "$LOOSE_REPLACE_WORK/feeds/packages/.git/refs/replace"
printf '%s\n' "$FEED_COMMIT" \
  > "$LOOSE_REPLACE_WORK/feeds/packages/.git/refs/replace/$FEED_COMMIT"
expect_history_override_rejection 'loose feed replace ref' \
  'forbidden Git replace/grafts metadata' "$LOOSE_REPLACE_WORK"
echo 'loose feed replace ref rejection: OK'

PACKED_REPLACE_WORK="$TMP_DIR/packed-feed-replace-work"
create_prepared_work "$PACKED_REPLACE_WORK"
"$REAL_GIT" -C "$PACKED_REPLACE_WORK/feeds/packages" pack-refs --all
printf '%s refs/replace/%s\n' "$FEED_COMMIT" "$FEED_COMMIT" \
  >> "$PACKED_REPLACE_WORK/feeds/packages/.git/packed-refs"
expect_history_override_rejection 'packed feed replace ref' \
  'forbidden packed Git replace refs' "$PACKED_REPLACE_WORK"
echo 'packed feed replace ref rejection: OK'

SYMLINK_REPLACE_WORK="$TMP_DIR/symlink-feed-replace-work"
create_prepared_work "$SYMLINK_REPLACE_WORK"
ln -s "$TMP_DIR/missing-feed-replace-target" \
  "$SYMLINK_REPLACE_WORK/feeds/packages/.git/refs/replace"
expect_history_override_rejection 'dangling feed replace symlink' \
  'forbidden Git replace/grafts metadata' "$SYMLINK_REPLACE_WORK"
echo 'dangling feed replace symlink rejection: OK'

GRAFTS_WORK="$TMP_DIR/feed-grafts-work"
create_prepared_work "$GRAFTS_WORK"
printf '%s\n' "$FEED_COMMIT" > "$GRAFTS_WORK/feeds/packages/.git/info/grafts"
expect_history_override_rejection 'feed info grafts' \
  'forbidden Git replace/grafts metadata' "$GRAFTS_WORK"
echo 'feed info/grafts rejection: OK'

WRONG_ORIGIN_WORK="$TMP_DIR/wrong-origin-work"
create_prepared_work "$WRONG_ORIGIN_WORK"
"$REAL_GIT" -C "$WRONG_ORIGIN_WORK/feeds/packages" \
  remote set-url --add origin "$TMP_DIR/not-canonical-feed"
expect_rebuild_attempt 'wrong feed origin' "$WRONG_ORIGIN_WORK"
echo 'wrong feed origin rebuild fallback: OK'

SINGLE_PUSHURL_WORK="$TMP_DIR/single-pushurl-work"
create_prepared_work "$SINGLE_PUSHURL_WORK"
"$REAL_GIT" -C "$SINGLE_PUSHURL_WORK/feeds/packages" config --add \
  remote.origin.pushurl "$TMP_DIR/not-canonical-feed-push"
expect_rebuild_attempt 'single feed pushurl' "$SINGLE_PUSHURL_WORK"
echo 'single feed pushurl rebuild fallback: OK'

MULTIPLE_PUSHURL_WORK="$TMP_DIR/multiple-pushurl-work"
create_prepared_work "$MULTIPLE_PUSHURL_WORK"
"$REAL_GIT" -C "$MULTIPLE_PUSHURL_WORK/feeds/packages" config --add \
  remote.origin.pushurl "$TMP_DIR/not-canonical-feed-push-one"
"$REAL_GIT" -C "$MULTIPLE_PUSHURL_WORK/feeds/packages" config --add \
  remote.origin.pushurl "$TMP_DIR/not-canonical-feed-push-two"
expect_rebuild_attempt 'multiple feed pushurls' "$MULTIPLE_PUSHURL_WORK"
echo 'multiple feed pushurl rebuild fallback: OK'

MISSING_BLOB_WORK="$TMP_DIR/missing-blob-work"
create_prepared_work "$MISSING_BLOB_WORK"
rm -rf "$MISSING_BLOB_WORK/feeds/packages"
mkdir -p "$MISSING_BLOB_WORK/feeds/packages"
"$REAL_GIT" -C "$MISSING_BLOB_WORK/feeds/packages" init -q
"$REAL_GIT" -C "$MISSING_BLOB_WORK/feeds/packages" remote add origin "$FEED_REPO"
[[ "$("$REAL_GIT" -C "$FEED_REPO" cat-file commit "$FEED_COMMIT" | \
  "$REAL_GIT" -C "$MISSING_BLOB_WORK/feeds/packages" hash-object -t commit -w --stdin)" == "$FEED_COMMIT" ]]
while read -r tree; do
  [[ "$("$REAL_GIT" -C "$FEED_REPO" cat-file tree "$tree" | \
    "$REAL_GIT" -C "$MISSING_BLOB_WORK/feeds/packages" hash-object -t tree -w --stdin)" == "$tree" ]]
done < <(
  {
    "$REAL_GIT" -C "$FEED_REPO" rev-parse "$FEED_COMMIT^{tree}"
    "$REAL_GIT" -C "$FEED_REPO" ls-tree -r -t "$FEED_COMMIT" | awk '$2 == "tree" { print $3 }'
  } | LC_ALL=C sort -u
)
"$REAL_GIT" -C "$MISSING_BLOB_WORK/feeds/packages" update-ref HEAD "$FEED_COMMIT"
expect_rebuild_attempt 'missing feed blob' "$MISSING_BLOB_WORK"
echo 'missing feed blob rebuild fallback: OK'

DIRTY_WORK="$TMP_DIR/dirty-work"
create_prepared_work "$DIRTY_WORK"
printf 'dirty\n' >> "$DIRTY_WORK/feeds/packages/pkg/Makefile"
expect_rebuild_attempt 'dirty feed checkout' "$DIRTY_WORK"
echo 'dirty feed checkout rebuild fallback: OK'

EXTRA_FEED_WORK="$TMP_DIR/extra-feed-work"
create_prepared_work "$EXTRA_FEED_WORK"
mkdir -p "$EXTRA_FEED_WORK/feeds/extra"
expect_rebuild_attempt 'extra feed top level' "$EXTRA_FEED_WORK"
echo 'extra feed top-level rebuild fallback: OK'

BAD_LINK_WORK="$TMP_DIR/bad-link-work"
create_prepared_work "$BAD_LINK_WORK"
rm "$BAD_LINK_WORK/package/feeds/packages/pkg"
ln -s ../../../feeds "$BAD_LINK_WORK/package/feeds/packages/pkg"
expect_rebuild_attempt 'bad package feed link' "$BAD_LINK_WORK"
echo 'bad package feed link rebuild fallback: OK'

echo 'feed reuse policy tests: OK'
