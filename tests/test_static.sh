#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Always exercise both static policies. If a source path is supplied, validate
# it using the caller-selected flavor after the repository-only checks.
SELECTED_FLAVOR="${NEXAWRT_FLAVOR:-official}"
NEXAWRT_FLAVOR=official "$ROOT_DIR/scripts/validate.sh"
NEXAWRT_FLAVOR=nss "$ROOT_DIR/scripts/validate.sh"
if (($#)); then
  NEXAWRT_FLAVOR="$SELECTED_FLAVOR" "$ROOT_DIR/scripts/validate.sh" "$@"
fi

official_prepare="$(make -s -n -C "$ROOT_DIR" prepare)"
nss_prepare="$(make -s -n -C "$ROOT_DIR" NEXAWRT_FLAVOR=nss prepare)"
grep -Fq 'NEXAWRT_FLAVOR=official WORK_DIR=.work/openwrt ./scripts/prepare.sh' <<<"$official_prepare"
grep -Fq 'NEXAWRT_FLAVOR=nss WORK_DIR=.work/openwrt-nss ./scripts/prepare.sh' <<<"$nss_prepare"

if NEXAWRT_FLAVOR=unknown "$ROOT_DIR/scripts/validate.sh" >/dev/null 2>&1; then
  echo 'invalid flavor unexpectedly accepted' >&2
  exit 1
fi

if NEXAWRT_FLAVOR=nss WORK_DIR="$ROOT_DIR/.work/openwrt-nss" \
  "$ROOT_DIR/scripts/release.sh" >/dev/null 2>&1; then
  echo 'experimental NSS release staging unexpectedly accepted' >&2
  exit 1
fi

echo 'flavor policy: official default, isolated nss work tree, and official-only release OK'
"$ROOT_DIR/tests/test_feed_policy.sh"
"$ROOT_DIR/tests/test_nss_artifact_policy.sh"
"$ROOT_DIR/tests/test_backup_guards.sh"
"$ROOT_DIR/tests/test_release_policy.sh"
