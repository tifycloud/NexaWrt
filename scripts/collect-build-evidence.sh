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

assert_source_and_feed_history_is_unmodified() {
  local entry

  git_history_overrides_absent "$WORK_DIR" "prepared OpenWrt source checkout" || return 1
  [[ -e "$WORK_DIR/feeds" || -L "$WORK_DIR/feeds" ]] || return 0
  [[ -d "$WORK_DIR/feeds" && ! -L "$WORK_DIR/feeds" ]] || {
    echo "prepared OpenWrt feeds state is missing or unsafe" >&2
    return 1
  }
  while IFS= read -r -d '' entry; do
    if [[ -L "$entry" ]]; then
      echo "feed state contains a symbolic top-level entry: $entry" >&2
      return 1
    fi
    [[ -d "$entry" ]] || continue
    [[ -d "$entry/.git" && ! -L "$entry/.git" ]] || {
      echo "feed checkout $(basename "$entry") has missing or unsafe Git metadata" >&2
      return 1
    }
    git_history_overrides_absent "$entry" "feed checkout $(basename "$entry")" || return 1
  done < <(find "$WORK_DIR/feeds" -mindepth 1 -maxdepth 1 -print0)
}

case "$FLAVOR" in official|nss) ;; *) fail "flavor must be official or nss" ;; esac
[[ -d "$WORK_DIR/.git" && ! -L "$WORK_DIR/.git" ]] || fail "prepared OpenWrt Git checkout is missing or unsafe"
[[ -f "$WORK_DIR/.config" ]] || fail "resolved OpenWrt .config is missing"
[[ -d "$DIST_DIR" ]] || fail "staging directory is missing"
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
trap 'rm -f "$INPUT_LIST"' EXIT
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

EVIDENCE_DIR="$DIST_DIR/EVIDENCE"
rm -rf "$EVIDENCE_DIR"
mkdir -p "$EVIDENCE_DIR"
cp "$BUILD_LOG" "$EVIDENCE_DIR/build.log"
cp "$WORK_DIR/.config" "$EVIDENCE_DIR/resolved.config"
{
  printf 'schema=1\n'
  printf 'flavor=%s\n' "$FLAVOR"
  printf 'replica_id=%s\n' "$REPLICA_ID"
  printf 'run_id=%s\n' "$RUN_ID"
  printf 'run_attempt=%s\n' "$RUN_ATTEMPT"
  printf 'project_commit=%s\n' "$PROJECT_COMMIT"
  printf 'source_commit=%s\n' "$SOURCE_COMMIT"
} > "$EVIDENCE_DIR/BUILD-IDENTITY.txt"

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
  printf 'source_origin=%s\n' "$(git -C "$WORK_DIR" remote get-url origin)"
  if [[ -d "$WORK_DIR/feeds" ]]; then
    while read -r feed; do
      [[ -n "$feed" && -d "$WORK_DIR/feeds/$feed/.git" ]] || continue
    printf 'feed.%s.commit=%s\n' "$feed" "$(git -C "$WORK_DIR/feeds/$feed" rev-parse HEAD)"
    printf 'feed.%s.origin=%s\n' "$feed" "$(git -C "$WORK_DIR/feeds/$feed" remote get-url origin)"
    diff_hash="$(git -C "$WORK_DIR/feeds/$feed" diff --binary --no-ext-diff HEAD -- | hash_file /dev/stdin | awk '{print $1}')"
    printf 'feed.%s.worktree_diff_sha256=%s\n' "$feed" "$diff_hash"
    done < <(find "$WORK_DIR/feeds" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | LC_ALL=C sort)
  fi
} > "$EVIDENCE_DIR/SOURCE-STATE.txt"

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
} > "$EVIDENCE_DIR/BUILD-ENVIRONMENT.txt"

(
  cd "$ROOT_DIR"
  while IFS= read -r -d '' file; do
    [[ -f "$file" && ! -L "$file" ]] || fail "enumerated build input changed or became unsafe: $file"
    hash_file "$file"
  done < "$INPUT_LIST"
) > "$EVIDENCE_DIR/INPUTS.sha256"

(
  cd "$EVIDENCE_DIR"
  while IFS= read -r file; do hash_file "$file"; done < <(find . -type f ! -name EVIDENCE.sha256 -print | LC_ALL=C sort)
) > "$EVIDENCE_DIR/EVIDENCE.sha256"
(
  cd "$EVIDENCE_DIR"
  if command -v sha256sum >/dev/null 2>&1; then sha256sum -c EVIDENCE.sha256 >/dev/null; else shasum -a 256 -c EVIDENCE.sha256 >/dev/null; fi
)

rm -f "$INPUT_LIST"
trap - EXIT
