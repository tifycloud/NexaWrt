#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NEXAWRT_FLAVOR="${NEXAWRT_FLAVOR:-official}"
case "$NEXAWRT_FLAVOR" in
  official)
    DEFAULT_WORK_DIR="$ROOT_DIR/.work/openwrt"
    DEFAULT_BUILD_LOG="$ROOT_DIR/build.log"
    ;;
  nss)
    DEFAULT_WORK_DIR="$ROOT_DIR/.work/openwrt-nss"
    DEFAULT_BUILD_LOG="$ROOT_DIR/build-nss.log"
    ;;
  *)
    echo "Unsupported NEXAWRT_FLAVOR: $NEXAWRT_FLAVOR (expected official or nss)" >&2
    exit 2
    ;;
esac
WORK_DIR="${WORK_DIR:-$DEFAULT_WORK_DIR}"
JOBS="${JOBS:-}"
BUILD_LOG="${BUILD_LOG:-$DEFAULT_BUILD_LOG}"

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

NEXAWRT_FLAVOR="$NEXAWRT_FLAVOR" WORK_DIR="$WORK_DIR" "$ROOT_DIR/scripts/prepare.sh"
cd "$WORK_DIR"

make download -j"$JOBS"
find dl -type f -size -1024c -delete

set +e
make -j"$JOBS" V=sc 2>&1 | tee "$BUILD_LOG"
status=${PIPESTATUS[0]}
set -e
if ((status != 0)); then
  echo "Build failed; see $BUILD_LOG" >&2
  exit "$status"
fi

NEXAWRT_FLAVOR="$NEXAWRT_FLAVOR" "$ROOT_DIR/scripts/validate.sh" \
  --source "$WORK_DIR" --artifacts
if [[ "$NEXAWRT_FLAVOR" == official ]]; then
  NEXAWRT_FLAVOR=official WORK_DIR="$WORK_DIR" "$ROOT_DIR/scripts/release.sh"
else
  NEXAWRT_FLAVOR=nss WORK_DIR="$WORK_DIR" "$ROOT_DIR/scripts/stage-nss-artifact.sh"
fi
