#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for command in sysupgrade firstboot jffs2reset jffs2mark factoryreset mount_root; do
  guard="$ROOT_DIR/files/sbin/$command"
  [[ -x "$guard" ]] || { echo "runtime guard is missing or not executable: $command" >&2; exit 1; }
  set +e
  output="$($guard 2>&1)"; status=$?
  set -e
  [[ "$status" == 74 ]] || { echo "runtime guard returned $status instead of 74: $command" >&2; exit 1; }
  grep -Fq "$command is disabled" <<<"$output" || { echo "runtime guard message missing: $command" >&2; exit 1; }
done
grep -Eq '^\+[[:space:]]*return 74$' "$ROOT_DIR/patches/002-ax9000-block-persistent-upgrade.patch" || {
  echo 'platform image check is not marked non-forceable' >&2; exit 1;
}

for label in '0:appsblenv' bdata pstore rootfs; do
  awk -v label="label = \"$label\";" '
    $0 ~ label { found=1; remaining=5 }
    found && /read-only;/ { ok=1; exit }
    remaining > 0 { remaining-- }
    END { exit(ok ? 0 : 1) }
  ' "$ROOT_DIR/patches/001-ax9000-single-large-ubi-layout.patch" || {
    echo "persistent partition is not made read-only by the project patch: $label" >&2
    exit 1
  }
done
echo 'runtime persistent-storage command and MTD read-only guards: OK'
