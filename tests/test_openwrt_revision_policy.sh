#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
VALIDATE="$ROOT_DIR/scripts/validate.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/nexawrt-openwrt-revision.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "test_openwrt_revision_policy: $*" >&2; exit 1; }

expect_failure() {
  local label="$1"
  local expected_message="$2"
  shift 2

  if "$@" >"$TMP/stdout" 2>"$TMP/stderr"; then
    fail "$label unexpectedly passed"
  fi
  grep -Fq "$expected_message" "$TMP/stderr" || {
    echo "$label failed for an unexpected reason" >&2
    cat "$TMP/stderr" >&2
    exit 1
  }
}

# shellcheck source=../manifests/upstream.lock
source "$ROOT_DIR/manifests/upstream.lock"
# shellcheck source=../manifests/nss.lock
source "$ROOT_DIR/manifests/nss.lock"

SOURCE="$TMP/source"
mkdir -p "$SOURCE"

run_policy() {
  local flavor="$1"
  REVISION='r0-environment-must-not-win' \
    NEXAWRT_FLAVOR="$flavor" "$VALIDATE" \
      --source "$SOURCE" --revision-policy-only
}

set_flavor_fixture() {
  local flavor="$1"
  local commit seed

  case "$flavor" in
    official)
      commit="$OPENWRT_COMMIT"
      seed="$ROOT_DIR/configs/ax9000-single-ubi.config"
      ;;
    nss)
      commit="$NSS_OPENWRT_COMMIT"
      seed="$ROOT_DIR/configs/ax9000-single-ubi-nss.config"
      ;;
    *) fail "unknown fixture flavor: $flavor" ;;
  esac
  EXPECTED_REVISION="r0-${commit:0:8}"
  cp "$seed" "$SOURCE/.config"
  rm -rf "$SOURCE/version"
  printf '%s\n' "$EXPECTED_REVISION" > "$SOURCE/version"
}

for flavor in official nss; do
  set_flavor_fixture "$flavor"
  run_policy "$flavor" >/dev/null
  echo "$flavor exact 8-character OpenWrt revision: OK"
done

set_flavor_fixture nss
rm "$SOURCE/version"
expect_failure 'missing version file' \
  'OpenWrt source version is missing or is not a non-symlink regular file' \
  run_policy nss

set_flavor_fixture nss
printf '%s\n' "$EXPECTED_REVISION" > "$TMP/version-target"
rm "$SOURCE/version"
ln -s "$TMP/version-target" "$SOURCE/version"
expect_failure 'symlink version file' \
  'OpenWrt source version is missing or is not a non-symlink regular file' \
  run_policy nss

set_flavor_fixture nss
printf 'r0-%s\n' "${NSS_OPENWRT_COMMIT:0:7}" > "$SOURCE/version"
expect_failure '7-character revision' \
  "OpenWrt source version must be exactly one line: r0-${NSS_OPENWRT_COMMIT:0:8}" \
  run_policy nss

set_flavor_fixture nss
printf 'r0-%s\n' "${OPENWRT_COMMIT:0:8}" > "$SOURCE/version"
expect_failure 'stale or cross-flavor revision' \
  "OpenWrt source version must be exactly one line: r0-${NSS_OPENWRT_COMMIT:0:8}" \
  run_policy nss

set_flavor_fixture nss
printf '%s\nextra-line\n' "$EXPECTED_REVISION" > "$SOURCE/version"
expect_failure 'extra-line revision' \
  "OpenWrt source version must be exactly one line: $EXPECTED_REVISION" \
  run_policy nss

# The resolved firmware version code must describe the same controlled source
# revision; a correct root version file cannot mask a stale resolved config.
set_flavor_fixture nss
python3 - "$SOURCE/.config" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
text = text.replace('CONFIG_VERSION_CODE="nexawrt-r0-d6848fa2"',
                    'CONFIG_VERSION_CODE="nexawrt-r0-d6848fa"')
path.write_text(text)
PY
expect_failure 'stale resolved VERSION_CODE' \
  'nss resolved config must contain exactly CONFIG_VERSION_CODE="nexawrt-r0-d6848fa2"' \
  run_policy nss

grep -Fq 'write_openwrt_revision' "$ROOT_DIR/scripts/prepare.sh" ||
  fail 'prepare.sh no longer writes the controlled OpenWrt revision file'
grep -Fq 'assert_openwrt_revision_file "$SOURCE_DIR"' "$ROOT_DIR/scripts/validate.sh" ||
  fail 'normal source validation no longer checks the controlled revision file'
grep -Fq 'openwrt_revision=%s' "$ROOT_DIR/scripts/build.sh" ||
  fail 'build evidence log no longer records the controlled OpenWrt revision'

echo 'OpenWrt root version fail-closed policy tests: OK'
