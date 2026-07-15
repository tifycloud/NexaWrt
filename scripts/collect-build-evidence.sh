#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=sanitize-git-environment.sh
source "$ROOT_DIR/scripts/sanitize-git-environment.sh"
nexawrt_sanitize_git_environment
# shellcheck source=git-metadata-policy.sh
source "$ROOT_DIR/scripts/git-metadata-policy.sh"
FLAVOR="${1:-}"
WORK_DIR="${2:-}"
DIST_DIR="${3:-}"
BUILD_LOG="${4:-}"

fail() { echo "build evidence refused: $*" >&2; exit 1; }
TEMP_FILES=()
TEMP_DIRS=()
cleanup_temp_paths() {
  if ((${#TEMP_FILES[@]})); then
    rm -f -- "${TEMP_FILES[@]}"
  fi
  if ((${#TEMP_DIRS[@]})); then
    rm -rf -- "${TEMP_DIRS[@]}"
  fi
}
trap cleanup_temp_paths EXIT

hash_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum -- "$1"; else shasum -a 256 -- "$1"; fi
}


git_history_overrides_absent() {
  nexawrt_git_metadata_is_safe "$1" "$2"
}

identity_value_is_safe() {
  local value="$1"
  ((${#value} >= 1 && ${#value} <= 128)) &&
    [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

assert_openwrt_base_feed_link_is_safe() {
  local base_link="$1"

  python3 -I - "$WORK_DIR" "$base_link" <<'PY_BASE_LINK'
import os
import pathlib
import stat
import sys


def refuse(message):
    print(message, file=sys.stderr)
    raise SystemExit(1)


work_dir = pathlib.Path(sys.argv[1])
base_link = pathlib.Path(sys.argv[2])

try:
    base_mode = os.lstat(base_link).st_mode
except OSError:
    refuse("feeds/base must be the OpenWrt package symlink")
if not stat.S_ISLNK(base_mode):
    refuse("feeds/base must be the OpenWrt package symlink")

try:
    target = os.readlink(base_link)
except OSError:
    refuse("feeds/base symlink target could not be read")
if target != "../package":
    refuse("feeds/base has an unexpected symlink target")

try:
    work_root = work_dir.resolve(strict=True)
except (OSError, RuntimeError):
    refuse("prepared OpenWrt source directory does not resolve")

package_dir = work_root / "package"
try:
    package_mode = os.lstat(package_dir).st_mode
except OSError:
    refuse("prepared OpenWrt package directory is missing or unsafe")
if not stat.S_ISDIR(package_mode):
    refuse("prepared OpenWrt package directory is missing or unsafe")

try:
    resolved_base = base_link.resolve(strict=True)
    resolved_package = package_dir.resolve(strict=True)
except (OSError, RuntimeError):
    refuse("feeds/base does not resolve")
if resolved_base != resolved_package:
    refuse("feeds/base does not resolve to the prepared OpenWrt package directory")
PY_BASE_LINK
}

TOP_LEVEL_FEED_ENTRIES=()
TOP_LEVEL_FEED_KINDS=()
TOP_LEVEL_FEED_IDENTITIES=()
TOP_LEVEL_FEED_SNAPSHOT_FILE=""
TOP_LEVEL_FEEDS_STATE="unset"

path_lstat_identity() {
  python3 -I - "$1" <<'PY_PATH_IDENTITY'
import os
import stat
import sys

path = sys.argv[1]
try:
    status = os.lstat(path)
except OSError as error:
    raise SystemExit(f"could not inspect {path}: {error}")
print(f"{status.st_dev}:{status.st_ino}:{stat.S_IFMT(status.st_mode)}")
PY_PATH_IDENTITY
}

feed_checkout_identity() {
  python3 -I - "$1" <<'PY_CHECKOUT_IDENTITY'
import os
import stat
import sys

checkout = sys.argv[1]
metadata = os.path.join(checkout, ".git")
identities = []
for description, path in (("feed checkout", checkout), ("feed Git metadata", metadata)):
    try:
        status = os.lstat(path)
    except OSError as error:
        raise SystemExit(f"{description} is missing or unsafe: {error}")
    if not stat.S_ISDIR(status.st_mode):
        raise SystemExit(f"{description} is not a non-symlink directory: {path}")
    identities.append(f"{status.st_dev}:{status.st_ino}:{stat.S_IFMT(status.st_mode)}")
print(":".join(identities))
PY_CHECKOUT_IDENTITY
}

assert_feed_has_no_untracked_files() {
  local checkout="$1"
  local feed="$2"
  local phase="$3"
  local untracked_file

  untracked_file="$(mktemp "${TMPDIR:-/tmp}/nexawrt-feed-untracked.XXXXXX")" || {
    echo "could not create temporary feed untracked list" >&2
    return 1
  }
  TEMP_FILES+=("$untracked_file")
  if ! git -C "$checkout" ls-files --others -z > "$untracked_file"; then
    echo "feed checkout $feed untracked file enumeration failed during $phase" >&2
    return 1
  fi
  if [[ -s "$untracked_file" ]]; then
    echo "feed checkout $feed contains untracked or ignored files during $phase" >&2
    return 1
  fi
}

enumerate_top_level_feed_entries() {
  local entries_file="$1"
  local snapshot_file="$2"

  if ! find "$WORK_DIR/feeds" -mindepth 1 -maxdepth 1 -print0 > "$entries_file"; then
    echo "top-level feed enumeration failed" >&2
    return 1
  fi
  if ! python3 -I - "$entries_file" "$snapshot_file" <<'PY_FEED_ENTRIES'
import os
import stat
import sys


entries_path = sys.argv[1]
snapshot_path = sys.argv[2]
with open(entries_path, "rb") as handle:
    data = handle.read()
if data and not data.endswith(b"\0"):
    raise SystemExit("feed entry list is not NUL terminated")
entries = data[:-1].split(b"\0") if data else []
if len(entries) != len(set(entries)):
    raise SystemExit("feed entry list contains duplicates")
entries.sort()
with open(entries_path, "wb") as handle:
    handle.write(b"\0".join(entries) + (b"\0" if entries else b""))

snapshot = []
for entry in entries:
    try:
        status = os.lstat(entry)
    except OSError as error:
        raise SystemExit(f"could not inspect enumerated feed entry: {error}")
    identity = f"{status.st_dev}:{status.st_ino}:{stat.S_IFMT(status.st_mode)}".encode("ascii")
    snapshot.extend((entry, identity))
with open(snapshot_path, "wb") as handle:
    handle.write(b"\0".join(snapshot) + (b"\0" if snapshot else b""))
PY_FEED_ENTRIES
  then
    echo "top-level feed enumeration is unsafe or malformed" >&2
    return 1
  fi
}

revalidate_top_level_feed_entry() {
  local index="$1"
  local entry="${TOP_LEVEL_FEED_ENTRIES[$index]}"
  local kind="${TOP_LEVEL_FEED_KINDS[$index]}"
  local expected_identity="${TOP_LEVEL_FEED_IDENTITIES[$index]}"
  local entry_name="${entry##*/}"
  local current_identity

  identity_value_is_safe "$entry_name" || {
    echo "feed entry name became unsafe: $entry_name" >&2
    return 1
  }
  case "$kind" in
    base)
      assert_openwrt_base_feed_link_is_safe "$entry" || return 1
      current_identity="$(path_lstat_identity "$entry")" || return 1
      ;;
    checkout)
      current_identity="$(feed_checkout_identity "$entry")" || return 1
      [[ "$current_identity" == "$expected_identity" ]] || {
        echo "feed checkout $entry_name changed after validation" >&2
        return 1
      }
      assert_feed_has_no_untracked_files "$entry" "$entry_name" "feed revalidation" || return 1
      git_history_overrides_absent "$entry" "feed checkout $entry_name" || return 1
      assert_feed_has_no_untracked_files "$entry" "$entry_name" "feed metadata revalidation" || return 1
      current_identity="$(feed_checkout_identity "$entry")" || return 1
      ;;
    other)
      [[ ! -L "$entry" ]] || {
        echo "feed entry $entry_name became a symbolic link" >&2
        return 1
      }
      current_identity="$(path_lstat_identity "$entry")" || return 1
      ;;
    *)
      echo "feed entry $entry_name has an unknown validation state" >&2
      return 1
      ;;
  esac
  [[ "$current_identity" == "$expected_identity" ]] || {
    echo "feed entry $entry_name changed after validation" >&2
    return 1
  }
}

revalidate_top_level_feed_entries() {
  local current_entries_file current_snapshot_file feed_index

  case "$TOP_LEVEL_FEEDS_STATE" in
    missing)
      [[ ! -e "$WORK_DIR/feeds" && ! -L "$WORK_DIR/feeds" ]] || {
        echo "prepared OpenWrt feeds state appeared after validation" >&2
        return 1
      }
      return 0
      ;;
    directory)
      [[ -d "$WORK_DIR/feeds" && ! -L "$WORK_DIR/feeds" ]] || {
        echo "prepared OpenWrt feeds state changed after validation" >&2
        return 1
      }
      ;;
    *)
      echo "prepared OpenWrt feeds state was not validated" >&2
      return 1
      ;;
  esac

  current_entries_file="$(mktemp "${TMPDIR:-/tmp}/nexawrt-feed-entries.XXXXXX")" || {
    echo "could not create temporary feed entry list" >&2
    return 1
  }
  TEMP_FILES+=("$current_entries_file")
  current_snapshot_file="$(mktemp "${TMPDIR:-/tmp}/nexawrt-feed-snapshot.XXXXXX")" || {
    echo "could not create temporary feed snapshot" >&2
    return 1
  }
  TEMP_FILES+=("$current_snapshot_file")
  enumerate_top_level_feed_entries "$current_entries_file" "$current_snapshot_file" || return 1
  if ! cmp -s -- "$TOP_LEVEL_FEED_SNAPSHOT_FILE" "$current_snapshot_file"; then
    echo "top-level feed entries changed after validation" >&2
    return 1
  fi
  for ((feed_index = 0; feed_index < ${#TOP_LEVEL_FEED_ENTRIES[@]}; feed_index++)); do
    revalidate_top_level_feed_entry "$feed_index" || return 1
  done
}

assert_source_and_feed_history_is_unmodified() {
  local entries_file snapshot_file entry entry_name entry_kind entry_identity result=0

  git_history_overrides_absent "$WORK_DIR" "prepared OpenWrt source checkout" || return 1
  if [[ ! -e "$WORK_DIR/feeds" && ! -L "$WORK_DIR/feeds" ]]; then
    TOP_LEVEL_FEEDS_STATE=missing
    TOP_LEVEL_FEED_ENTRIES=()
    TOP_LEVEL_FEED_KINDS=()
    TOP_LEVEL_FEED_IDENTITIES=()
    return 0
  fi
  [[ -d "$WORK_DIR/feeds" && ! -L "$WORK_DIR/feeds" ]] || {
    echo "prepared OpenWrt feeds state is missing or unsafe" >&2
    return 1
  }
  TOP_LEVEL_FEEDS_STATE=directory

  entries_file="$(mktemp "${TMPDIR:-/tmp}/nexawrt-feed-entries.XXXXXX")" || {
    echo "could not create temporary feed entry list" >&2
    return 1
  }
  TEMP_FILES+=("$entries_file")
  snapshot_file="$(mktemp "${TMPDIR:-/tmp}/nexawrt-feed-snapshot.XXXXXX")" || {
    echo "could not create temporary feed snapshot" >&2
    return 1
  }
  TEMP_FILES+=("$snapshot_file")
  enumerate_top_level_feed_entries "$entries_file" "$snapshot_file" || return 1
  TOP_LEVEL_FEED_SNAPSHOT_FILE="$snapshot_file"

  TOP_LEVEL_FEED_ENTRIES=()
  TOP_LEVEL_FEED_KINDS=()
  TOP_LEVEL_FEED_IDENTITIES=()
  while IFS= read -r -d '' entry; do
    entry_name="${entry##*/}"
    if ! identity_value_is_safe "$entry_name"; then
      echo "feed entry name is unsafe: $entry_name" >&2
      result=1
      break
    fi
    if [[ "$entry_name" == base ]]; then
      if ! assert_openwrt_base_feed_link_is_safe "$entry"; then
        result=1
        break
      fi
      entry_kind=base
      entry_identity="$(path_lstat_identity "$entry")" || {
        result=1
        break
      }
    elif [[ -L "$entry" ]]; then
      echo "feed state contains a symbolic top-level entry: $entry" >&2
      result=1
      break
    elif [[ -d "$entry" ]]; then
      if [[ ! -d "$entry/.git" || -L "$entry/.git" ]]; then
        echo "feed checkout $entry_name has missing or unsafe Git metadata" >&2
        result=1
        break
      fi
      entry_identity="$(feed_checkout_identity "$entry")" || {
        result=1
        break
      }
      if ! assert_feed_has_no_untracked_files "$entry" "$entry_name" "initial validation"; then
        result=1
        break
      fi
      if ! git_history_overrides_absent "$entry" "feed checkout $entry_name"; then
        result=1
        break
      fi
      if ! assert_feed_has_no_untracked_files "$entry" "$entry_name" "post-metadata validation"; then
        result=1
        break
      fi
      if [[ "$(feed_checkout_identity "$entry")" != "$entry_identity" ]]; then
        echo "feed checkout $entry_name changed during validation" >&2
        result=1
        break
      fi
      entry_kind=checkout
    else
      entry_kind=other
      entry_identity="$(path_lstat_identity "$entry")" || {
        result=1
        break
      }
    fi
    TOP_LEVEL_FEED_ENTRIES+=("$entry")
    TOP_LEVEL_FEED_KINDS+=("$entry_kind")
    TOP_LEVEL_FEED_IDENTITIES+=("$entry_identity")
  done < "$entries_file"
  if ((result == 0)); then
    revalidate_top_level_feed_entries || result=1
  fi
  return "$result"
}
case "$FLAVOR" in official|nss) ;; *) fail "flavor must be official or nss" ;; esac
[[ -d "$WORK_DIR/.git" && ! -L "$WORK_DIR/.git" ]] || fail "prepared OpenWrt Git checkout is missing or unsafe"
[[ -f "$WORK_DIR/.config" ]] || fail "resolved OpenWrt .config is missing"
[[ -d "$DIST_DIR" ]] || fail "staging directory is missing"
EVIDENCE_DIR="$DIST_DIR/EVIDENCE"
rm -rf "$EVIDENCE_DIR"
[[ -f "$BUILD_LOG" ]] || fail "build log is missing: $BUILD_LOG"
assert_source_and_feed_history_is_unmodified || fail "Git replace/grafts policy failed"

PROJECT_COMMIT="$(git -C "$ROOT_DIR" rev-parse --verify 'HEAD^{commit}' 2>/dev/null)" ||
  fail "project commit could not be resolved"
SOURCE_COMMIT="$(git -C "$WORK_DIR" rev-parse --verify 'HEAD^{commit}' 2>/dev/null)" ||
  fail "source commit could not be resolved"
[[ "$PROJECT_COMMIT" =~ ^[0-9a-f]{40}$ ]] || fail "project commit is not a full SHA-1 object ID"
[[ "$SOURCE_COMMIT" =~ ^[0-9a-f]{40}$ ]] || fail "source commit is not a full SHA-1 object ID"
REPLICA_ID="${NEXAWRT_BUILD_REPLICA:-local}"
RUN_ID="${GITHUB_RUN_ID:-local}"
RUN_ATTEMPT="${GITHUB_RUN_ATTEMPT:-local}"
identity_value_is_safe "$FLAVOR" || fail "flavor contains unsafe identity characters"
identity_value_is_safe "$REPLICA_ID" || fail "replica_id contains unsafe identity characters"
identity_value_is_safe "$RUN_ID" || fail "run_id contains unsafe identity characters"
identity_value_is_safe "$RUN_ATTEMPT" || fail "run_attempt contains unsafe identity characters"

INPUT_LISTER="$ROOT_DIR/scripts/list-build-inputs.sh"
[[ -f "$INPUT_LISTER" && ! -L "$INPUT_LISTER" && -x "$INPUT_LISTER" ]] ||
  fail "build input lister is missing, unsafe, or not executable"
INPUT_LIST="$(mktemp "${TMPDIR:-/tmp}/nexawrt-build-inputs.XXXXXX")" ||
  fail "could not create temporary build input list"
TEMP_FILES+=("$INPUT_LIST")
if ! "$INPUT_LISTER" "$FLAVOR" > "$INPUT_LIST"; then
  fail "build input enumeration failed"
fi
python3 - "$ROOT_DIR" "$INPUT_LIST" <<'PY_INPUTS' || fail "build input enumeration is unsafe or malformed"
import pathlib
import stat
import sys

root = pathlib.Path(sys.argv[1]).resolve(strict=True)
data = pathlib.Path(sys.argv[2]).read_bytes()
if not data or not data.endswith(b"\0"):
    raise SystemExit("input list must be non-empty and NUL terminated")
raw_entries = data[:-1].split(b"\0")
try:
    entries = [entry.decode("utf-8", "strict") for entry in raw_entries]
except UnicodeDecodeError as error:
    raise SystemExit(f"input list is not UTF-8: {error}")
if any(not entry for entry in entries):
    raise SystemExit("input list contains an empty path")
if entries != sorted(set(entries)):
    raise SystemExit("input list is not sorted and unique")
if "scripts/list-build-inputs.sh" not in entries:
    raise SystemExit("input lister does not enumerate itself")
for entry in entries:
    relative = pathlib.PurePosixPath(entry)
    if relative.is_absolute() or any(part in {"", ".", ".."} for part in relative.parts):
        raise SystemExit(f"unsafe input path: {entry}")
    path = root.joinpath(*relative.parts)
    mode = path.lstat().st_mode
    if stat.S_ISLNK(mode) or not stat.S_ISREG(mode):
        raise SystemExit(f"input is not a non-symlink regular file: {entry}")
PY_INPUTS

# Public upstream-only builds should never need credentials. Refuse to archive
# a log that looks as if a token or private key was accidentally printed.
if grep -Eq '(^|[^[:alnum:]_])(gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----)' "$BUILD_LOG"; then
  fail "build log appears to contain a credential or private key"
fi

EVIDENCE_STAGING_DIR="$(mktemp -d "$DIST_DIR/.EVIDENCE.XXXXXX")" ||
  fail "could not create temporary evidence staging directory"
TEMP_DIRS+=("$EVIDENCE_STAGING_DIR")
cp "$BUILD_LOG" "$EVIDENCE_STAGING_DIR/build.log"
cp "$WORK_DIR/.config" "$EVIDENCE_STAGING_DIR/resolved.config"
{
  printf 'schema=1\n'
  printf 'flavor=%s\n' "$FLAVOR"
  printf 'replica_id=%s\n' "$REPLICA_ID"
  printf 'run_id=%s\n' "$RUN_ID"
  printf 'run_attempt=%s\n' "$RUN_ATTEMPT"
  printf 'project_commit=%s\n' "$PROJECT_COMMIT"
  printf 'source_commit=%s\n' "$SOURCE_COMMIT"
} > "$EVIDENCE_STAGING_DIR/BUILD-IDENTITY.txt"

SOURCE_STATE_TMP="$(mktemp "$EVIDENCE_STAGING_DIR/.SOURCE-STATE.XXXXXX")" ||
  fail "could not create temporary source state file"
TEMP_FILES+=("$SOURCE_STATE_TMP")
revalidate_top_level_feed_entries || fail "feed state changed before SOURCE-STATE collection"
{
  printf 'flavor=%s\n' "$FLAVOR"
  printf 'project_commit=%s\n' "$PROJECT_COMMIT"
  if git -C "$ROOT_DIR" diff --quiet --ignore-submodules -- &&
     git -C "$ROOT_DIR" diff --cached --quiet --ignore-submodules -- &&
     [[ -z "$(git -C "$ROOT_DIR" ls-files --others --exclude-standard)" ]]; then
    printf 'project_tree_state=clean\n'
  else
    printf 'project_tree_state=dirty\n'
  fi
  printf 'source_commit=%s\n' "$SOURCE_COMMIT"
  source_origin="$(git -C "$WORK_DIR" remote get-url origin)" ||
    fail "source origin could not be resolved"
  printf 'source_origin=%s\n' "$source_origin"
  if ((${#TOP_LEVEL_FEED_ENTRIES[@]})); then
    for ((feed_index = 0; feed_index < ${#TOP_LEVEL_FEED_ENTRIES[@]}; feed_index++)); do
      revalidate_top_level_feed_entries || fail "feed state changed before evidence collection"
      [[ "${TOP_LEVEL_FEED_KINDS[$feed_index]}" == checkout ]] || continue
      checkout="${TOP_LEVEL_FEED_ENTRIES[$feed_index]}"
      feed="${checkout##*/}"
      feed_commit="$(git -C "$checkout" rev-parse --verify 'HEAD^{commit}')" ||
        fail "feed checkout $feed commit could not be resolved"
      [[ "$feed_commit" =~ ^[0-9a-f]{40}$ ]] || fail "feed checkout $feed commit is not a full SHA-1 object ID"
      feed_origin="$(git -C "$checkout" remote get-url origin)" ||
        fail "feed checkout $feed origin could not be resolved"
      feed_head_after_origin="$(git -C "$checkout" rev-parse --verify 'HEAD^{commit}')" ||
        fail "feed checkout $feed commit could not be rechecked after origin collection"
      [[ "$feed_head_after_origin" == "$feed_commit" ]] ||
        fail "feed checkout $feed HEAD changed during origin collection"
      diff_hash="$(git -C "$checkout" diff --binary --no-ext-diff "$feed_commit" -- | hash_file /dev/stdin | awk '{print $1}')" ||
        fail "feed checkout $feed worktree diff could not be hashed"
      [[ "$diff_hash" =~ ^[0-9a-f]{64}$ ]] || fail "feed checkout $feed worktree diff hash is invalid"
      assert_feed_has_no_untracked_files "$checkout" "$feed" "after worktree diff collection" ||
        fail "feed checkout $feed contains untracked files after worktree diff collection"
      feed_head_after_diff="$(git -C "$checkout" rev-parse --verify 'HEAD^{commit}')" ||
        fail "feed checkout $feed commit could not be rechecked after diff collection"
      [[ "$feed_head_after_diff" == "$feed_commit" ]] ||
        fail "feed checkout $feed HEAD changed during diff collection"
      feed_origin_after="$(git -C "$checkout" remote get-url origin)" ||
        fail "feed checkout $feed origin could not be rechecked"
      [[ "$feed_origin_after" == "$feed_origin" ]] ||
        fail "feed checkout $feed origin changed during evidence collection"
      feed_head_after_origin_recheck="$(git -C "$checkout" rev-parse --verify 'HEAD^{commit}')" ||
        fail "feed checkout $feed commit could not be rechecked after origin recheck"
      [[ "$feed_head_after_origin_recheck" == "$feed_commit" ]] ||
        fail "feed checkout $feed HEAD changed during origin recheck"
      revalidate_top_level_feed_entries || fail "feed state changed during evidence collection"
      feed_origin_final="$(git -C "$checkout" remote get-url origin)" ||
        fail "feed checkout $feed origin could not be finally rechecked"
      [[ "$feed_origin_final" == "$feed_origin" ]] ||
        fail "feed checkout $feed origin changed before final diff collection"
      feed_head_final="$(git -C "$checkout" rev-parse --verify 'HEAD^{commit}')" ||
        fail "feed checkout $feed commit could not be finally rechecked"
      [[ "$feed_head_final" == "$feed_commit" ]] ||
        fail "feed checkout $feed HEAD changed before final diff collection"
      final_diff_hash="$(git -C "$checkout" diff --binary --no-ext-diff "$feed_commit" -- | hash_file /dev/stdin | awk '{print $1}')" ||
        fail "feed checkout $feed final worktree diff could not be hashed"
      [[ "$final_diff_hash" =~ ^[0-9a-f]{64}$ ]] || fail "feed checkout $feed final worktree diff hash is invalid"
      assert_feed_has_no_untracked_files "$checkout" "$feed" "after final worktree diff collection" ||
        fail "feed checkout $feed contains untracked files after final worktree diff collection"
      feed_head_after_final_diff="$(git -C "$checkout" rev-parse --verify 'HEAD^{commit}')" ||
        fail "feed checkout $feed commit could not be rechecked after final diff collection"
      [[ "$feed_head_after_final_diff" == "$feed_commit" ]] ||
        fail "feed checkout $feed HEAD changed during final diff collection"
      feed_origin_after_final_diff="$(git -C "$checkout" remote get-url origin)" ||
        fail "feed checkout $feed origin could not be rechecked after final diff collection"
      [[ "$feed_origin_after_final_diff" == "$feed_origin" ]] ||
        fail "feed checkout $feed origin changed during final diff collection"
      [[ "$final_diff_hash" == "$diff_hash" ]] ||
        fail "feed checkout $feed worktree diff changed before recording evidence"
      printf 'feed.%s.commit=%s\n' "$feed" "$feed_commit"
      printf 'feed.%s.origin=%s\n' "$feed" "$feed_origin"
      printf 'feed.%s.worktree_diff_sha256=%s\n' "$feed" "$diff_hash"
    done
  fi
} > "$SOURCE_STATE_TMP"
revalidate_top_level_feed_entries || fail "feed state changed after SOURCE-STATE collection"
mv -- "$SOURCE_STATE_TMP" "$EVIDENCE_STAGING_DIR/SOURCE-STATE.txt"

{
  printf 'uname='; uname -a
  [[ -r /etc/os-release ]] && cat /etc/os-release
  printf 'shell=%s\n' "${SHELL:-unknown}"
  printf 'PATH=%s\n' "$PATH"
  for command in bash git make gcc g++ clang ld python3 perl tar gzip xz zstd; do
    if command -v "$command" >/dev/null 2>&1; then
      printf '\n[%s]\n' "$command"
      "$command" --version 2>&1 | head -n 3 || true
    fi
  done
  if command -v dpkg-query >/dev/null 2>&1; then
    printf '\n[dpkg]\n'
    dpkg-query -W -f='${binary:Package}\t${Version}\n' | LC_ALL=C sort
  fi
} > "$EVIDENCE_STAGING_DIR/BUILD-ENVIRONMENT.txt"

(
  cd "$ROOT_DIR"
  while IFS= read -r -d '' file; do
    [[ -f "$file" && ! -L "$file" ]] || fail "enumerated build input changed or became unsafe: $file"
    hash_file "$file"
  done < "$INPUT_LIST"
) > "$EVIDENCE_STAGING_DIR/INPUTS.sha256"

EVIDENCE_FILE_LIST="$(mktemp "$DIST_DIR/.nexawrt-evidence-files.XXXXXX")" ||
  fail "could not create temporary evidence file list"
TEMP_FILES+=("$EVIDENCE_FILE_LIST")
if ! (
  cd "$EVIDENCE_STAGING_DIR"
  find . -type f ! -name EVIDENCE.sha256 -print0 > "$EVIDENCE_FILE_LIST"
); then
  fail "evidence file enumeration failed"
fi
if ! python3 -I - "$EVIDENCE_FILE_LIST" <<'PY_EVIDENCE_FILES'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
data = path.read_bytes()
if data and not data.endswith(b"\0"):
    raise SystemExit("evidence file list is not NUL terminated")
entries = data[:-1].split(b"\0") if data else []
if not entries or len(entries) != len(set(entries)):
    raise SystemExit("evidence file list is empty or contains duplicates")
entries.sort()
path.write_bytes(b"\0".join(entries) + b"\0")
PY_EVIDENCE_FILES
then
  fail "evidence file enumeration is unsafe or malformed"
fi
EVIDENCE_MANIFEST_TMP="$(mktemp "$DIST_DIR/.EVIDENCE.sha256.XXXXXX")" ||
  fail "could not create temporary evidence manifest"
TEMP_FILES+=("$EVIDENCE_MANIFEST_TMP")
(
  cd "$EVIDENCE_STAGING_DIR"
  while IFS= read -r -d '' file; do
    [[ -f "$file" && ! -L "$file" ]] || fail "enumerated evidence file changed or became unsafe: $file"
    hash_file "$file"
  done < "$EVIDENCE_FILE_LIST"
) > "$EVIDENCE_MANIFEST_TMP"
(
  cd "$EVIDENCE_STAGING_DIR"
  if command -v sha256sum >/dev/null 2>&1; then sha256sum -c "$EVIDENCE_MANIFEST_TMP" >/dev/null; else shasum -a 256 -c "$EVIDENCE_MANIFEST_TMP" >/dev/null; fi
)
revalidate_top_level_feed_entries || fail "feed state changed before evidence manifest publication"
mv -- "$EVIDENCE_MANIFEST_TMP" "$EVIDENCE_STAGING_DIR/EVIDENCE.sha256"
revalidate_top_level_feed_entries || fail "feed state changed before final evidence publication"
python3 -I - "$EVIDENCE_STAGING_DIR" "$EVIDENCE_DIR" <<'PY_PUBLISH_EVIDENCE'
import os
import sys

staging, final = sys.argv[1], sys.argv[2]
try:
    os.lstat(final)
except FileNotFoundError:
    pass
else:
    raise SystemExit("final evidence directory appeared before publication")
os.rename(staging, final)
PY_PUBLISH_EVIDENCE

cleanup_temp_paths
TEMP_FILES=()
TEMP_DIRS=()
trap - EXIT
