#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
CHECKER="$ROOT_DIR/scripts/check-kernel-build-identity.sh"
FLAVOR="${1:-}"
SOURCE_DIR="${2:-}"
TMP=""

fail() { echo "test_openwrt_defconfig_version: $*" >&2; exit 1; }
cleanup() {
  if [[ -n "$TMP" ]]; then
    rm -rf "$TMP"
  fi
}
trap cleanup EXIT

case "$FLAVOR" in
  official)
    # shellcheck source=../manifests/upstream.lock
    source "$ROOT_DIR/manifests/upstream.lock"
    SOURCE_REPO="$OPENWRT_REPO"
    SOURCE_COMMIT="$OPENWRT_COMMIT"
    SEED_CONFIG="$ROOT_DIR/configs/ax9000-single-ubi.config"
    ;;
  nss)
    # shellcheck source=../manifests/nss.lock
    source "$ROOT_DIR/manifests/nss.lock"
    SOURCE_REPO="$NSS_OPENWRT_REPO"
    SOURCE_COMMIT="$NSS_OPENWRT_COMMIT"
    SEED_CONFIG="$ROOT_DIR/configs/ax9000-single-ubi-nss.config"
    ;;
  *)
    echo "Usage: $0 official|nss [DISPOSABLE_OPENWRT_SOURCE]" >&2
    exit 2
    ;;
esac

TMP="$(mktemp -d "${TMPDIR:-/tmp}/nexawrt-openwrt-defconfig.XXXXXX")"
if [[ -z "$SOURCE_DIR" ]]; then
  SOURCE_DIR="$TMP/source"
  mkdir "$SOURCE_DIR"
  git -C "$SOURCE_DIR" init -q
  git -C "$SOURCE_DIR" remote add origin "$SOURCE_REPO"
  git -C "$SOURCE_DIR" -c advice.detachedHead=false fetch -q --depth=1 origin "$SOURCE_COMMIT"
  git -C "$SOURCE_DIR" checkout -q --detach FETCH_HEAD
else
  SOURCE_DIR="$(cd "$SOURCE_DIR" && pwd -P)"
  case "$SOURCE_DIR" in
    "$ROOT_DIR"|"$ROOT_DIR"/*)
      fail "source must be a disposable checkout outside the repository workspace"
      ;;
  esac
  [[ -f "$SOURCE_DIR/scripts/config/Makefile" ]] ||
    fail "source does not contain OpenWrt scripts/config: $SOURCE_DIR"
  if [[ -d "$SOURCE_DIR/.git" ]]; then
    [[ "$(git -C "$SOURCE_DIR" rev-parse HEAD)" == "$SOURCE_COMMIT" ]] ||
      fail "$FLAVOR source is not at its locked commit"
  else
    [[ "$(basename "$SOURCE_DIR")" == *"$SOURCE_COMMIT"* ]] ||
      fail "non-Git source path does not identify the locked $FLAVOR commit"
  fi
fi

[[ -f "$SOURCE_DIR/config/Config-kernel.in" ]] || fail "locked source lacks Config-kernel.in"
[[ -f "$SOURCE_DIR/package/base-files/image-config.in" ]] ||
  fail "locked source lacks base-files image-config.in"
grep -Fq 'config KERNEL_BUILD_USER' "$SOURCE_DIR/config/Config-kernel.in" ||
  fail "locked source lacks KERNEL_BUILD_USER Kconfig definition"
grep -Fq 'config KERNEL_BUILD_DOMAIN' "$SOURCE_DIR/config/Config-kernel.in" ||
  fail "locked source lacks KERNEL_BUILD_DOMAIN Kconfig definition"
grep -Fq 'config VERSION_CODE' "$SOURCE_DIR/package/base-files/image-config.in" ||
  fail "locked source lacks VERSION_CODE Kconfig definition"
grep -Fq 'config VERSION_FILENAMES' "$SOURCE_DIR/package/base-files/image-config.in" ||
  fail "locked source lacks VERSION_FILENAMES Kconfig definition"
grep -Fq 'config VERSION_CODE_FILENAMES' "$SOURCE_DIR/package/base-files/image-config.in" ||
  fail "locked source lacks VERSION_CODE_FILENAMES Kconfig definition"

# Build the exact locked source's OpenWrt Kconfig frontend. The top-level
# OpenWrt defconfig target invokes this binary with --defconfig=.config; the
# small disposable fixture below reproduces that recipe while avoiding target,
# feed, and build-tree preparation.
make -s -C "$SOURCE_DIR/scripts/config" conf

FIXTURE="$TMP/fixture"
mkdir -p "$FIXTURE/tmp"
: > "$FIXTURE/tmp/.config-feeds.in"
ln -s "$SOURCE_DIR/config" "$FIXTURE/config"
mkdir -p "$FIXTURE/package/base-files"
ln -s "$SOURCE_DIR/package/base-files/image-config.in" \
  "$FIXTURE/package/base-files/image-config.in"
cat > "$FIXTURE/Config.in" <<'EOF_CONFIG_IN'
mainmenu "NexaWrt OpenWrt defconfig retention fixture"

menuconfig IMAGEOPT
	bool "Image configuration"
	default n

source "config/Config-kernel.in"
source "package/base-files/image-config.in"
EOF_CONFIG_IN
cat > "$FIXTURE/Makefile" <<'EOF_MAKE'
.PHONY: defconfig
defconfig:
	touch .config
	$(OPENWRT_CONF) --defconfig=.config Config.in
EOF_MAKE
cp "$SEED_CONFIG" "$FIXTURE/.config"
make -s -C "$FIXTURE" defconfig \
  OPENWRT_CONF="$SOURCE_DIR/scripts/config/conf"

"$CHECKER" "$FIXTURE/.config" "$SOURCE_COMMIT" "$FLAVOR defconfig fixture result"
expected_version="nexawrt-r0-${SOURCE_COMMIT:0:8}"
[[ "$(grep -Fxc 'CONFIG_IMAGEOPT=y' "$FIXTURE/.config")" == 1 ]] ||
  fail "$FLAVOR OpenWrt defconfig did not preserve CONFIG_IMAGEOPT=y"
[[ "$(grep -Fxc 'CONFIG_VERSIONOPT=y' "$FIXTURE/.config")" == 1 ]] ||
  fail "$FLAVOR OpenWrt defconfig did not preserve CONFIG_VERSIONOPT=y"
[[ "$(grep -Fxc "CONFIG_VERSION_CODE=\"$expected_version\"" "$FIXTURE/.config")" == 1 ]] ||
  fail "$FLAVOR OpenWrt defconfig did not preserve the deterministic product version"
[[ "$(grep -Fxc '# CONFIG_VERSION_FILENAMES is not set' "$FIXTURE/.config")" == 1 ]] ||
  fail "$FLAVOR OpenWrt defconfig did not keep version numbers out of artifact filenames"
[[ "$(grep -Fxc '# CONFIG_VERSION_CODE_FILENAMES is not set' "$FIXTURE/.config")" == 1 ]] ||
  fail "$FLAVOR OpenWrt defconfig did not keep version codes out of artifact filenames"

echo "$FLAVOR locked OpenWrt Kconfig make defconfig preserved $expected_version with canonical artifact filenames: OK"
