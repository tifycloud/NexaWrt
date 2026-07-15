#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; BUILD="$ROOT_DIR/.github/workflows/build.yml"; RELEASE="$ROOT_DIR/.github/workflows/release.yml"
for workflow in "$BUILD" "$RELEASE"; do
  while read -r use; do
    [[ "$use" =~ @[0-9a-f]{40}$ ]] || { echo "workflow action is not pinned to a full commit: $use" >&2; exit 1; }
  done < <(sed -nE 's/^[[:space:]]*uses:[[:space:]]*([^ #]+).*/\1/p' "$workflow")
done
grep -Fq 'persist-credentials: false' "$BUILD"
grep -Fq 'persist-credentials: false' "$RELEASE"
grep -Fq 'shellcheck -S warning' "$BUILD"
grep -Fq 'shellcheck -S warning' "$RELEASE"
grep -Fq 'merge_group:' "$BUILD"
grep -Fq 'branches: [main]' "$BUILD"
grep -Fq 'permissions: {}' "$RELEASE"
grep -Fq 'cancel-in-progress: false' "$RELEASE"
grep -Fq 'replica: [a, b]' "$RELEASE"
grep -Fq 'compare-reproducible-builds.sh' "$RELEASE"
grep -Fq 'release-staging/verified-dist' "$RELEASE"
grep -Fq 'environment: ram-test-release' "$RELEASE"
grep -Fq 'git cat-file -t "refs/tags/$GITHUB_REF_NAME"' "$RELEASE"
grep -Fq 'git/ref/tags/$GITHUB_REF_NAME' "$RELEASE"
grep -Fq 'test "$remote_sha" = "$GITHUB_SHA"' "$RELEASE"
grep -Fq 'gh release create "$GITHUB_REF_NAME" --verify-tag --draft --prerelease' "$RELEASE"
grep -Fq 'attestations: write' "$RELEASE"
grep -Fq 'actions/attest-build-provenance@96278af6caaf10aea03fd8d33a09a777ca52d62f' "$RELEASE"
[[ "$(grep -c 'contents: write' "$RELEASE")" == 1 ]] || { echo 'release write permission is not isolated to one job' >&2; exit 1; }
[[ "$(grep -Fc 'PIPESTATUS[@]' "$ROOT_DIR/scripts/build.sh")" == 2 ]] || { echo 'build pipelines do not capture both pipeline exit statuses' >&2; exit 1; }
grep -Fq 'download_tee_status' "$ROOT_DIR/scripts/build.sh"
grep -Fq 'build_tee_status' "$ROOT_DIR/scripts/build.sh"
policy_tmp="$(mktemp -d "$ROOT_DIR/.work/test-build-path-policy.XXXXXX")"
outside_tmp="$(mktemp -d)"
trap 'rm -rf "$policy_tmp" "$outside_tmp"' EXIT
if WORK_DIR="$outside_tmp/outside-work" BUILD_LOG="$ROOT_DIR/build-policy.log" "$ROOT_DIR/scripts/build.sh" >"$policy_tmp/stdout" 2>"$policy_tmp/stderr"; then
  echo 'build accepted a work directory outside .work' >&2; exit 1
fi
grep -Fq 'Unsafe WORK_DIR' "$policy_tmp/stderr"
if WORK_DIR="$ROOT_DIR/.work/build-path-policy" BUILD_LOG="$outside_tmp/outside.log" "$ROOT_DIR/scripts/build.sh" >"$policy_tmp/stdout" 2>"$policy_tmp/stderr"; then
  echo 'build accepted a log path outside safe build-log roots' >&2; exit 1
fi
grep -Fq 'Unsafe BUILD_LOG' "$policy_tmp/stderr"
! grep -Eq '^[[:space:]]*assert[[:space:]]' \
  "$ROOT_DIR/scripts/release.sh" \
  "$ROOT_DIR/scripts/stage-nss-artifact.sh" \
  "$ROOT_DIR/scripts/compare-reproducible-builds.sh" \
  "$ROOT_DIR/scripts/validate.sh"
# Build commands must not appear after the publish job starts.
! awk '/^  publish:/{p=1} p' "$RELEASE" | grep -Eq 'scripts/(build|prepare)\.sh'
echo 'GitHub workflow least-privilege, reproducibility, and approval policy: OK'
