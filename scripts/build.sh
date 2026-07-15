#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${WORK_DIR:-$ROOT_DIR/.work/openwrt}"
JOBS="${JOBS:-}"

if [[ "$(uname -s)" != Linux && "${ALLOW_UNSUPPORTED_HOST:-0}" != 1 ]]; then
  cat >&2 <<'MSG'
Full OpenWrt builds are supported here only on Linux. On macOS, use the pinned
GitHub Actions workflow or a case-sensitive Linux VM/container. Set
ALLOW_UNSUPPORTED_HOST=1 only if you have already prepared a supported macOS
build environment on a case-sensitive filesystem.
MSG
  exit 1
fi

if [[ -z "$JOBS" ]]; then
  JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)"
fi

"$ROOT_DIR/scripts/prepare.sh"
cd "$WORK_DIR"

make download -j"$JOBS"
find dl -type f -size -1024c -delete

set +e
make -j"$JOBS" V=sc 2>&1 | tee "$ROOT_DIR/build.log"
status=${PIPESTATUS[0]}
set -e
if ((status != 0)); then
  echo "Build failed; see $ROOT_DIR/build.log" >&2
  exit "$status"
fi

"$ROOT_DIR/scripts/validate.sh" --source "$WORK_DIR" --artifacts
"$ROOT_DIR/scripts/release.sh"
