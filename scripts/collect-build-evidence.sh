#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLAVOR="${1:-}"
WORK_DIR="${2:-}"
DIST_DIR="${3:-}"
BUILD_LOG="${4:-}"

fail() { echo "build evidence refused: $*" >&2; exit 1; }
hash_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum -- "$1"; else shasum -a 256 -- "$1"; fi
}

case "$FLAVOR" in official|nss) ;; *) fail "flavor must be official or nss" ;; esac
[[ -d "$WORK_DIR/.git" ]] || fail "prepared OpenWrt Git checkout is missing"
[[ -f "$WORK_DIR/.config" ]] || fail "resolved OpenWrt .config is missing"
[[ -d "$DIST_DIR" ]] || fail "staging directory is missing"
[[ -f "$BUILD_LOG" ]] || fail "build log is missing: $BUILD_LOG"

# Public upstream-only builds should never need credentials. Refuse to archive
# a log that looks as if a token or private key was accidentally printed.
if grep -Eiq '(^|[^[:alnum:]_])(gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----)' "$BUILD_LOG"; then
  fail "build log appears to contain a credential or private key"
fi

EVIDENCE_DIR="$DIST_DIR/EVIDENCE"
rm -rf "$EVIDENCE_DIR"
mkdir -p "$EVIDENCE_DIR"
cp "$BUILD_LOG" "$EVIDENCE_DIR/build.log"
cp "$WORK_DIR/.config" "$EVIDENCE_DIR/resolved.config"

{
  printf 'flavor=%s\n' "$FLAVOR"
  printf 'project_commit=%s\n' "$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null || printf unknown)"
  if git -C "$ROOT_DIR" diff --quiet --ignore-submodules -- &&
     git -C "$ROOT_DIR" diff --cached --quiet --ignore-submodules -- &&
     [[ -z "$(git -C "$ROOT_DIR" ls-files --others --exclude-standard)" ]]; then
    printf 'project_tree_state=clean\n'
  else
    printf 'project_tree_state=dirty\n'
  fi
  printf 'source_commit=%s\n' "$(git -C "$WORK_DIR" rev-parse HEAD)"
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
  input_paths=(
    Makefile
    scripts/build.sh
    scripts/prepare.sh
    scripts/validate.sh
    scripts/collect-build-evidence.sh
    files
    manifests/upstream.lock
    manifests/feeds.lock
    patches/001-ax9000-single-large-ubi-layout.patch
    patches/002-ax9000-block-persistent-upgrade.patch
  )
  if [[ "$FLAVOR" == official ]]; then
    input_paths+=(configs/ax9000-single-ubi.config scripts/release.sh)
  else
    input_paths+=(
      configs/ax9000-single-ubi-nss.config
      manifests/nss.lock
      patches/nss
      files-nss
      scripts/stage-nss-artifact.sh
    )
  fi
  while IFS= read -r -d '' file; do
    hash_file "$file"
  done < <(find "${input_paths[@]}" -type f -print0 | LC_ALL=C sort -z)
) > "$EVIDENCE_DIR/INPUTS.sha256"

(
  cd "$EVIDENCE_DIR"
  while IFS= read -r file; do hash_file "$file"; done < <(find . -type f ! -name EVIDENCE.sha256 -print | LC_ALL=C sort)
) > "$EVIDENCE_DIR/EVIDENCE.sha256"
(
  cd "$EVIDENCE_DIR"
  if command -v sha256sum >/dev/null 2>&1; then sha256sum -c EVIDENCE.sha256 >/dev/null; else shasum -a 256 -c EVIDENCE.sha256 >/dev/null; fi
)
