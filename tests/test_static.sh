#!/usr/bin/env bash
set -euo pipefail
# Repository policy tests run as local fixtures unless a case injects a complete
# synthetic GitHub context explicitly. Do not inherit the enclosing CI run identity.
unset GITHUB_ACTIONS GITHUB_REF GITHUB_REPOSITORY GITHUB_RUN_ATTEMPT \
  GITHUB_RUN_ID GITHUB_SHA GITHUB_WORKFLOW_REF GITHUB_WORKFLOW_SHA
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 "$ROOT_DIR/tests/test_component_catalog.py"
"$ROOT_DIR/tests/test_custom_build_policy.sh"
python3 "$ROOT_DIR/tests/test_custom_artifacts.py"

# Always exercise both static policies. If a source path is supplied, validate
# it using the caller-selected flavor after the repository-only checks.
SELECTED_FLAVOR="${NEXAWRT_FLAVOR:-official}"
NEXAWRT_FLAVOR=official "$ROOT_DIR/scripts/validate.sh"
NEXAWRT_FLAVOR=nss "$ROOT_DIR/scripts/validate.sh"
if (($#)); then
  NEXAWRT_FLAVOR="$SELECTED_FLAVOR" "$ROOT_DIR/scripts/validate.sh" "$@"
fi

official_prepare="$(env -u NEXAWRT_FLAVOR make -s -n -C "$ROOT_DIR" prepare)"
nss_prepare="$(make -s -n -C "$ROOT_DIR" NEXAWRT_FLAVOR=nss prepare)"
grep -Fq 'env NEXAWRT_FLAVOR="official" WORK_DIR=".work/openwrt" ./scripts/prepare.sh' <<<"$official_prepare"
grep -Fq 'env NEXAWRT_FLAVOR="nss" WORK_DIR=".work/openwrt-nss" ./scripts/prepare.sh' <<<"$nss_prepare"
spaced_validate="$(env -u NEXAWRT_FLAVOR make -s -n -C "$ROOT_DIR" WORK_DIR='build path/with spaces' validate)"
grep -Fq 'env NEXAWRT_FLAVOR="official" ./scripts/validate.sh --source "build path/with spaces"' <<<"$spaced_validate"

if NEXAWRT_FLAVOR=unknown "$ROOT_DIR/scripts/validate.sh" >/dev/null 2>&1; then
  echo 'invalid flavor unexpectedly accepted' >&2
  exit 1
fi

if NEXAWRT_FLAVOR=nss WORK_DIR="$ROOT_DIR/.work/openwrt-nss" \
  "$ROOT_DIR/scripts/release.sh" >/dev/null 2>&1; then
  echo 'experimental NSS release staging unexpectedly accepted' >&2
  exit 1
fi

# Downstream policy tests intentionally exercise Makefile defaults; do not leak
# a caller-selected release flavor into those independent default-value checks.
unset NEXAWRT_FLAVOR

echo 'flavor policy: official default, isolated nss work tree, and official-only release OK'
"$ROOT_DIR/tests/test_apk_signing_policy.sh"
"$ROOT_DIR/tests/test_feed_policy.sh"
"$ROOT_DIR/tests/test_git_environment_policy.sh"
"$ROOT_DIR/tests/test_source_fetch_policy.sh"
"$ROOT_DIR/tests/test_feed_reuse_policy.sh"
"$ROOT_DIR/tests/test_nss_artifact_policy.sh"
"$ROOT_DIR/tests/test_backup_guards.sh"
"$ROOT_DIR/tests/test_runtime_guards.sh"
"$ROOT_DIR/tests/test_build_evidence_policy.sh"
"$ROOT_DIR/tests/test_kernel_build_identity_policy.sh"
"$ROOT_DIR/tests/test_openwrt_revision_policy.sh"
"$ROOT_DIR/tests/test_readonly_envtools_policy.sh"
"$ROOT_DIR/tests/test_create_hardware_session.sh"
"$ROOT_DIR/tests/test_runtime_probe.sh"
"$ROOT_DIR/tests/test_evidence_collectors.sh"
"$ROOT_DIR/tests/test_post_reboot_gate.sh"
"$ROOT_DIR/tests/test_stress_gate.sh"
"$ROOT_DIR/tests/test_hardware_gate.sh"
"$ROOT_DIR/tests/test_release_policy.sh"
"$ROOT_DIR/tests/test_reproducibility_policy.sh"
"$ROOT_DIR/tests/test_browser_build_policy.sh"
"$ROOT_DIR/tests/test_vm_policy.sh"
"$ROOT_DIR/tests/test_vm_release_policy.sh"
"$ROOT_DIR/tests/test_vm_runtime_gate.sh"
# Includes strict identity-matched, idempotent stable-draft recovery coverage.
"$ROOT_DIR/tests/test_vm_promotion_policy.sh"
"$ROOT_DIR/tests/test_pages_policy.sh"
"$ROOT_DIR/tests/test_workflow_policy.sh"
