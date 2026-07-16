#!/usr/bin/env bash
set -euo pipefail

CHECKOUT_RAW="${1:-}"
[[ -n "$CHECKOUT_RAW" ]] || { echo "usage: $0 GIT_CHECKOUT" >&2; exit 2; }
CHECKOUT="$(cd "$CHECKOUT_RAW" 2>/dev/null && pwd -P)" || {
  echo "complete Git diff refused: checkout is missing" >&2
  exit 1
}
[[ -d "$CHECKOUT/.git" && ! -L "$CHECKOUT/.git" ]] || {
  echo "complete Git diff refused: checkout metadata is missing or unsafe" >&2
  exit 1
}

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nexawrt-git-index.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT
TEMP_INDEX="$TEMP_DIR/index"

# A temporary index makes untracked additions visible without changing the real
# checkout index. Ignored files remain excluded and are validated separately by
# the feed policy callers.
GIT_INDEX_FILE="$TEMP_INDEX" git -C "$CHECKOUT" read-tree HEAD
GIT_INDEX_FILE="$TEMP_INDEX" git -C "$CHECKOUT" add -A -- .
GIT_INDEX_FILE="$TEMP_INDEX" git -C "$CHECKOUT" diff \
  --cached --binary --no-ext-diff HEAD --
