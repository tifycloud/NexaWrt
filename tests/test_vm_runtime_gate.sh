#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE_SCRIPT="$ROOT_DIR/vm-files-release/etc/init.d/nexawrt-runtime-gate"
DEFAULTS_SCRIPT="$ROOT_DIR/vm-files-release/etc/uci-defaults/10-vm-release"
VM_TEST_SCRIPT="$ROOT_DIR/scripts/test-vm-release.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  printf 'test_vm_runtime_gate: %s\n' "$*" >&2
  exit 1
}

ETC_ROOT="$TMP_DIR/etc"
SYS_ROOT="$TMP_DIR/sys"
FAKE_BIN="$TMP_DIR/bin"
EVIDENCE_DIR="$TMP_DIR/evidence"
CONSOLE="$TMP_DIR/console"
mkdir -p "$ETC_ROOT/init.d" "$SYS_ROOT/class/net/eth1" "$FAKE_BIN" "$EVIDENCE_DIR"
printf '%s\n' 'root:x:20000:0:99999:7:::' >"$ETC_ROOT/shadow"
printf '%s\n' '0123456789abcdef0123456789abcdef' >"$ETC_ROOT/nexawrt-install-id"

cat >"$ETC_ROOT/init.d/firewall" <<'SH'
#!/bin/sh
[ "${1:-}" = enabled ]
SH
cat >"$ETC_ROOT/init.d/dropbear" <<'SH'
#!/bin/sh
exit 1
SH
cat >"$FAKE_BIN/nft" <<'SH'
#!/bin/sh
[ "${NEXAWRT_TEST_NFT:-pass}" = pass ]
SH
cat >"$FAKE_BIN/ip" <<'SH'
#!/bin/sh
printf '%s\n' '2: eth0: <UP>' '    inet 192.168.8.1/24 scope global eth0'
SH
cat >"$FAKE_BIN/uci" <<'SH'
#!/bin/sh
key="${3:-}"
case "$key" in
  uhttpd.main.redirect_https) printf '%s\n' 1 ;;
  network.lan.device) printf '%s\n' eth0 ;;
  network.lan.proto) printf '%s\n' static ;;
  dhcp.lan.ignore) printf '%s\n' 0 ;;
  network.wan.device) printf '%s\n' eth1 ;;
  network.wan.proto) printf '%s\n' dhcp ;;
  *) exit 1 ;;
esac
SH
cat >"$FAKE_BIN/pidof" <<'SH'
#!/bin/sh
exit 1
SH
cat >"$FAKE_BIN/sleep" <<'SH'
#!/bin/sh
exit 0
SH
chmod 0755 "$ETC_ROOT/init.d/firewall" "$ETC_ROOT/init.d/dropbear" "$FAKE_BIN"/*

run_gate() {
  PATH="$FAKE_BIN:$PATH" \
  NEXAWRT_RUNTIME_CONSOLE="$CONSOLE" \
  NEXAWRT_RUNTIME_ETC_ROOT="$ETC_ROOT" \
  NEXAWRT_RUNTIME_SYS_ROOT="$SYS_ROOT" \
  NEXAWRT_RUNTIME_EVIDENCE_DIR="$EVIDENCE_DIR" \
  NEXAWRT_RUNTIME_MAX_ATTEMPTS=2 \
  NEXAWRT_RUNTIME_RETRY_DELAY=0 \
    sh -c '. "$1"; run' runtime-test "$GATE_SCRIPT"
}

run_gate
for expected in \
  NEXAWRT_VM_PRODUCTION_RUNTIME_V1_BEGIN \
  network_mode=router \
  lan_device=eth0 \
  lan_address=192.168.8.1 \
  wan_device=eth1 \
  https_redirect=PASS \
  firewall_enabled=PASS \
  nftables_fw4=PASS \
  lan_dhcp=PASS \
  root_password=UNIQUE_FIRST_BOOT_VALUE \
  ssh_disabled=PASS \
  NEXAWRT_VM_PRODUCTION_RUNTIME_V1_END; do
  grep -Fxq "$expected" "$CONSOLE" || fail "success evidence missing: $expected"
done
cmp -s "$CONSOLE" "$EVIDENCE_DIR/production-runtime.evidence" ||
  fail 'console and atomic evidence file differ'

: >"$CONSOLE"
if NEXAWRT_TEST_NFT=fail run_gate; then
  fail 'gate accepted a missing fw4 nftables table'
fi
grep -Fxq 'NEXAWRT_VM_PRODUCTION_RUNTIME_FAILED=nftables_fw4_missing' "$CONSOLE" ||
  fail 'failure reason was not emitted to the console'
grep -Fxq 'NEXAWRT_VM_PRODUCTION_RUNTIME_FAILED=nftables_fw4_missing' \
  "$EVIDENCE_DIR/production-runtime.failed" || fail 'failure evidence file missing'

grep -Fxq 'USE_PROCD=1' "$GATE_SCRIPT" || fail 'runtime gate must use the procd rc.common path'
grep -Fxq "EXTRA_COMMANDS='run'" "$GATE_SCRIPT" || fail 'runtime gate run action is not registered with rc.common'

PROCD_LOG="$TMP_DIR/procd.log"
PROCD_LOG="$PROCD_LOG" sh -c '
  initscript=/etc/init.d/nexawrt-runtime-gate
  procd_open_instance() { printf "open:%s\n" "$1" >>"$PROCD_LOG"; }
  procd_set_param() { printf "param:%s\n" "$*" >>"$PROCD_LOG"; }
  procd_close_instance() { printf "close\n" >>"$PROCD_LOG"; }
  . "$1"
  start_service
' procd-test "$GATE_SCRIPT"
grep -Fxq 'open:gate' "$PROCD_LOG" || fail 'procd gate instance was not opened'
grep -Fxq 'param:command /etc/init.d/nexawrt-runtime-gate run' "$PROCD_LOG" ||
  fail 'procd worker command is not the explicit run action'
grep -Fxq 'close' "$PROCD_LOG" || fail 'procd gate instance was not closed'

grep -Fq '/etc/init.d/nexawrt-runtime-gate start >/dev/null 2>&1 || {' "$DEFAULTS_SCRIPT" ||
  fail 'first boot does not register the gate with procd'
if grep -Eq 'nexawrt-runtime-gate start.*[[:space:]]&[[:space:]]*$' "$DEFAULTS_SCRIPT"; then
  fail 'unmanaged background gate launch remains in uci-defaults'
fi
grep -Fq '/etc/init.d/nexawrt-runtime-gate enable' "$DEFAULTS_SCRIPT" ||
  fail 'runtime gate is not enabled for subsequent boots'
grep -Fq 'NEXAWRT_VM_PRODUCTION_RUNTIME_FAILED=procd_registration' "$DEFAULTS_SCRIPT" ||
  fail 'procd registration failure is not emitted to the console'
grep -Fq 'production runtime gate reported failure' "$VM_TEST_SCRIPT" ||
  fail 'QEMU validator does not fail fast on a runtime gate failure marker'

printf '%s\n' 'VM runtime gate tests passed.'
