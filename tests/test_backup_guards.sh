#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

cat >"$TMP_DIR/ssh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
cmd=${!#}
case "$cmd" in
  'printf "connected\n"') exit 0 ;;
  'cat /proc/mtd')
    cat <<'OUT'
dev:    size   erasesize  name
mtd7: 0e800000 00020000 "rootfs"
OUT
    ;;
  'cat /proc/cmdline') printf '%s\n' 'console=ttyMSM0 ubi.mtd=rootfs root=/dev/ubiblock0_1' ;;
  *'/tmp/sysinfo/board_name'*) printf 'board_name=xiaomi,ax9000\nmodel=Xiaomi AX9000\n' ;;
  *'/sys/class/mtd/mtd[0-9]*'*)
    printf 'mtd7\trootfs\t18350080\t243269632\t131072\n'
    ;;
  *'/sys/class/ubi/ubi[0-9]*'*)
    cat <<'OUT'
device	ubi0	7
volume	ubi0	0	kernel
volume	ubi0	1	rootfs
volume	ubi0	2	WRONG_NAME
OUT
    ;;
  'dmesg'|'uname -a'|*'command -v ubinfo'*|*'command -v fw_printenv'*) printf 'mock\n' ;;
  *)
    # The layout guard must fail before any MTD dd is attempted.
    if [[ $cmd == dd\ if=* ]]; then
      echo "unexpected flash read: $cmd" >&2
      exit 90
    fi
    exit 0
    ;;
esac
MOCK
chmod +x "$TMP_DIR/ssh"

set +e
PATH="$TMP_DIR:$PATH" "$ROOT_DIR/scripts/backup-router.sh" \
  --host mock-router --output "$TMP_DIR/backup" >"$TMP_DIR/stdout" 2>"$TMP_DIR/stderr"
status=$?
set -e

[[ $status -ne 0 ]]
grep -Fq 'UBI volume 2 on ubi0 is not named rootfs_data' "$TMP_DIR/stderr"
[[ ! -e "$TMP_DIR/backup" ]]
echo 'backup guard mock: OK'
