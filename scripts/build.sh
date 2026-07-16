#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=sanitize-git-environment.sh
source "$ROOT_DIR/scripts/sanitize-git-environment.sh"
nexawrt_sanitize_git_environment
# shellcheck source=git-metadata-policy.sh
source "$ROOT_DIR/scripts/git-metadata-policy.sh"
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
APK_SIGNING_TOOL="$ROOT_DIR/scripts/apk-signing-key.sh"


git_history_overrides_absent() {
  nexawrt_git_metadata_is_safe "$1" "$2"
}

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
git_history_overrides_absent "$WORK_DIR" "prepared OpenWrt source checkout" || exit 1
cd "$WORK_DIR"
SOURCE_COMMIT="$(git rev-parse --verify 'HEAD^{commit}')" || {
  echo "Prepared OpenWrt source commit could not be resolved" >&2
  exit 1
}
[[ "$SOURCE_COMMIT" =~ ^[0-9a-f]{40}$ ]] || {
  echo "Prepared OpenWrt source commit is not a full object ID" >&2
  exit 1
}
SOURCE_DATE_EPOCH="$(git show -s --format=%ct "$SOURCE_COMMIT")" || {
  echo "Unable to derive SOURCE_DATE_EPOCH from the prepared source commit" >&2
  exit 1
}
[[ "$SOURCE_DATE_EPOCH" =~ ^[0-9]+$ ]] || {
  echo "Prepared source commit has an invalid SOURCE_DATE_EPOCH" >&2
  exit 1
}
export SOURCE_DATE_EPOCH
OPENWRT_REVISION="r0-${SOURCE_COMMIT:0:8}"
[[ -f version && ! -L version ]] &&
  cmp -s -- version <(printf '%s\n' "$OPENWRT_REVISION") || {
  echo "Prepared OpenWrt revision seed is missing, unsafe, or stale" >&2
  exit 1
}
# OpenWrt's resolved CONFIG_KERNEL_BUILD_USER/DOMAIN locks are authoritative.
# Keep matching exports as defense for direct/ancillary kernel make paths, and
# prevent KBUILD_BUILD_VERSION from auto-incrementing between clean builds.
export KBUILD_BUILD_USER=nexawrt
export KBUILD_BUILD_HOST=builder
export KBUILD_BUILD_VERSION=0

if [[ -e private-key.pem || -L private-key.pem ]]; then
  echo "Refusing APK private key inside OpenWrt TOPDIR" >&2
  exit 1
fi

case "$CLEAN_BUILD" in
  1)
    rm -rf build_dir staging_dir tmp bin logs
    rm -f -- public-key.pem
    ;;
  0) ;;
  *) echo "CLEAN_BUILD must be 0 or 1" >&2; exit 2 ;;
esac

IFS=$'\t' read -r APK_SIGNING_PROFILE APK_SIGNING_PUBLIC_SHA256 APK_SIGNING_PUBLIC_KEY < <(
  /bin/bash "$APK_SIGNING_TOOL" prepare "$WORK_DIR"
) || {
  echo "APK signing public key preparation failed" >&2
  exit 1
}
[[ -n "$APK_SIGNING_PROFILE" && -n "$APK_SIGNING_PUBLIC_SHA256" &&
   -n "$APK_SIGNING_PUBLIC_KEY" ]] || {
  echo "APK signing public key preparation returned incomplete metadata" >&2
  exit 1
}
export NEXAWRT_APK_SIGNING_PROFILE="$APK_SIGNING_PROFILE"
export NEXAWRT_APK_SIGNING_PUBLIC_SHA256="$APK_SIGNING_PUBLIC_SHA256"
export NEXAWRT_APK_SIGNING_PUBLIC_KEY_FILE="$APK_SIGNING_PUBLIC_KEY"
/bin/bash "$APK_SIGNING_TOOL" verify-public
APK_MAKE_ARGS=(
  "NEXAWRT_APK_PUBLIC_ONLY=1"
  "BUILD_KEY_APK_PUB=$APK_SIGNING_PUBLIC_KEY"
)

assert_no_topdir_private_key() {
  if [[ -e "$WORK_DIR/private-key.pem" || -L "$WORK_DIR/private-key.pem" ]]; then
    rm -f -- "$WORK_DIR/private-key.pem"
    echo "OpenWrt attempted to create a private key inside TOPDIR" >&2
    return 1
  fi
}

{
  printf 'NexaWrt build start\n'
  printf 'flavor=%s\nsource_commit=%s\nopenwrt_revision=%s\nsource_date_epoch=%s\njobs=%s\nclean_build=%s\n' \
    "$NEXAWRT_FLAVOR" "$SOURCE_COMMIT" "$OPENWRT_REVISION" \
    "$SOURCE_DATE_EPOCH" "$JOBS" "$CLEAN_BUILD"
  printf 'apk_signing_profile=%s\napk_signing_public_sha256=%s\n' \
    "$APK_SIGNING_PROFILE" "$APK_SIGNING_PUBLIC_SHA256"
  uname -a
} > "$BUILD_LOG"

set +e
make "${APK_MAKE_ARGS[@]}" download -j"$JOBS" 2>&1 | tee -a "$BUILD_LOG"
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
assert_no_topdir_private_key || exit 1
find dl -type f -size -1024c -delete

set +e
make "${APK_MAKE_ARGS[@]}" -j"$JOBS" V=sc 2>&1 | tee -a "$BUILD_LOG"
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

assert_no_topdir_private_key || exit 1

if [[ "$NEXAWRT_FLAVOR" == official ]]; then
  NEXAWRT_FLAVOR=official WORK_DIR="$WORK_DIR" BUILD_LOG="$BUILD_LOG" "$ROOT_DIR/scripts/release.sh"
else
  NEXAWRT_FLAVOR=nss WORK_DIR="$WORK_DIR" BUILD_LOG="$BUILD_LOG" "$ROOT_DIR/scripts/stage-nss-artifact.sh"
fi
