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
CLEAN_BUILD="${CLEAN_BUILD:-1}"

canonicalize_output_path() {
  python3 - "$ROOT_DIR" "$1" "$2" <<'PY_CANONICAL'
import os
import pathlib
import sys

root = pathlib.Path(sys.argv[1]).resolve(strict=True)
raw = pathlib.Path(sys.argv[2])
policy = sys.argv[3]
absolute = pathlib.Path(os.path.abspath(root / raw if not raw.is_absolute() else raw))
work_root = root / ".work"
if policy == "work":
    allowed_root = work_root
    try:
        relative = absolute.relative_to(allowed_root)
    except ValueError:
        raise SystemExit("work output is outside .work")
else:
    if absolute.parent == root and absolute.name.startswith("build") and absolute.suffix == ".log":
        allowed_root = root
        relative = pathlib.Path(absolute.name)
    else:
        allowed_root = work_root
        try:
            relative = absolute.relative_to(allowed_root)
        except ValueError:
            raise SystemExit("log output is outside the safe build-log roots")
if not relative.parts:
    raise SystemExit(f"{policy} output may not be the staging root itself")
if os.path.lexists(allowed_root) and allowed_root.is_symlink():
    raise SystemExit(f"{policy} output root is a symlink: {allowed_root}")
current = allowed_root
for part in relative.parts:
    current = current / part
    if os.path.lexists(current) and current.is_symlink():
        raise SystemExit(f"{policy} output path contains a symlink: {current}")
canonical = absolute.resolve(strict=False)
try:
    canonical.relative_to(allowed_root)
except ValueError:
    raise SystemExit(f"canonical {policy} output is outside its project workspace root")
print(canonical)
PY_CANONICAL
}

WORK_DIR="$(canonicalize_output_path "$WORK_DIR" work)" || {
  echo "Unsafe WORK_DIR: $WORK_DIR" >&2
  exit 1
}
BUILD_LOG="$(canonicalize_output_path "$BUILD_LOG" log)" || {
  echo "Unsafe BUILD_LOG: $BUILD_LOG" >&2
  exit 1
}

export LC_ALL=C
export LANG=C
export TZ=UTC
umask 022
if [[ "$(id -u)" == 0 ]]; then
  export FORCE_UNSAFE_CONFIGURE=1
fi

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
SOURCE_DATE_EPOCH="$(git show -s --format=%ct HEAD)"
export SOURCE_DATE_EPOCH

case "$CLEAN_BUILD" in
  1) rm -rf build_dir staging_dir tmp bin logs ;;
  0) ;;
  *) echo "CLEAN_BUILD must be 0 or 1" >&2; exit 2 ;;
esac

{
  printf 'NexaWrt build start\n'
  printf 'flavor=%s\nsource_date_epoch=%s\njobs=%s\nclean_build=%s\n' \
    "$NEXAWRT_FLAVOR" "$SOURCE_DATE_EPOCH" "$JOBS" "$CLEAN_BUILD"
  uname -a
} > "$BUILD_LOG"

set +e
make download -j"$JOBS" 2>&1 | tee -a "$BUILD_LOG"
download_pipeline_status=("${PIPESTATUS[@]}")
set -e
download_make_status="${download_pipeline_status[0]}"
download_tee_status="${download_pipeline_status[1]}"
if ((download_tee_status != 0)); then
  echo "Download log capture failed; see $BUILD_LOG" >&2
  exit "$download_tee_status"
fi
if ((download_make_status != 0)); then
  echo "Download failed; see $BUILD_LOG" >&2
  exit "$download_make_status"
fi
find dl -type f -size -1024c -delete

set +e
make -j"$JOBS" V=sc 2>&1 | tee -a "$BUILD_LOG"
build_pipeline_status=("${PIPESTATUS[@]}")
set -e
build_make_status="${build_pipeline_status[0]}"
build_tee_status="${build_pipeline_status[1]}"
if ((build_tee_status != 0)); then
  echo "Build log capture failed; see $BUILD_LOG" >&2
  exit "$build_tee_status"
fi
if ((build_make_status != 0)); then
  echo "Build failed; see $BUILD_LOG" >&2
  exit "$build_make_status"
fi

if [[ "$NEXAWRT_FLAVOR" == official ]]; then
  NEXAWRT_FLAVOR=official WORK_DIR="$WORK_DIR" BUILD_LOG="$BUILD_LOG" "$ROOT_DIR/scripts/release.sh"
else
  NEXAWRT_FLAVOR=nss WORK_DIR="$WORK_DIR" BUILD_LOG="$BUILD_LOG" "$ROOT_DIR/scripts/stage-nss-artifact.sh"
fi
