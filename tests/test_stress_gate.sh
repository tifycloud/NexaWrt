#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/nexawrt-stress-gate.XXXXXX")"
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
E="$TMP/evidence"; mkdir "$E"
SESSION='abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789'
FINGERPRINT="$(printf 'xiaomi,ax9000\nethaddr=00:11:22:33:44:55\n' | sha256sum | awk '{print $1}')"
BOOT_ID='12345678-1234-4123-8123-123456789abc'
OTHER_BOOT_ID='87654321-4321-4321-8321-cba987654321'
fail() { echo "test_stress_gate: $*" >&2; exit 1; }
expect_failure() { local label="$1"; shift; if "$@" >/dev/null 2>&1; then fail "$label unexpectedly passed"; fi; }

write_runtime_inputs() {
  local directory="$1"
  printf 'session_id=%s\n' "$SESSION" > "$directory/SESSION.txt"
  cat > "$directory/runtime-gate.txt" <<EOF_RUNTIME
root=/dev/ram0
persistent_ubi_attached=no
persistent_mounts=no
all_mtd_partitions_readonly=yes
raw_mtd_write_probe=blocked
session_id=$SESSION
device_fingerprint_sha256=$FINGERPRINT
EOF_RUNTIME
}
write_runtime_inputs "$E"
cat > "$E/stress-gate.txt" <<EOF_GATE
stress_24h=pass
execution_mode=production
session_id=$SESSION
device_fingerprint_sha256=$FINGERPRINT
device_boot_id=$BOOT_ID
started_device_uptime_seconds=10000
ended_device_uptime_seconds=96400
network_regression=pass
panic_oops=none
thermal_throttle=none
elapsed_seconds=86400
network_min_mbps=500
network_rounds=24
thermal_limit_millidegrees=95000
thermal_max_millidegrees=70000
round_interval_seconds=3600
iperf_seconds=30
EOF_GATE
cat > "$E/stress-24h.log" <<EOF_LOG
schema=3
execution_mode=production
session_id=$SESSION
device_fingerprint_sha256=$FINGERPRINT
device_boot_id=$BOOT_ID
started_device_uptime_seconds=10000
ended_device_uptime_seconds=96400
started_epoch=100000
ended_epoch=186400
started_monotonic_seconds=50000
ended_monotonic_seconds=136400
elapsed_seconds=86400
completed=yes
rounds=24
round_interval_seconds=3600
iperf_seconds=30
ssh_failures=0
iperf_failures=0
panic_oops_matches=0
thermal_throttle_matches=0
EOF_LOG
: > "$E/network-regression.log"; : > "$E/thermal.log"; : > "$E/kernel-health.log"
for round in $(seq 1 24); do
  epoch=$((100000 + (round - 1) * 3600))
  mono=$((50000 + (round - 1) * 3600))
  uptime=$((10000 + (round - 1) * 3600))
  prefix="round=$round epoch=$epoch monotonic_seconds=$mono boot_id=$BOOT_ID device_uptime_seconds=$uptime"
  printf '%s direction=forward mbps=900.0 status=pass\n' "$prefix" >> "$E/network-regression.log"
  printf '%s direction=reverse mbps=850.0 status=pass\n' "$prefix" >> "$E/network-regression.log"
  printf '%s zone=thermal_zone0:cpu millidegrees=70000\n' "$prefix" >> "$E/thermal.log"
  printf '%s panic_oops_matches=0 thermal_throttle_matches=0 status=pass\n' "$prefix" >> "$E/kernel-health.log"
done
"$ROOT_DIR/scripts/verify-stress-evidence.sh" "$E" >/dev/null

expect_failure 'live runner short duration' "$ROOT_DIR/scripts/run-ax9000-stress-gate.sh" root@192.0.2.1 "$E" 192.0.2.2 500 86399
expect_failure 'live runner unsafe server' "$ROOT_DIR/scripts/run-ax9000-stress-gate.sh" root@192.0.2.1 "$E" 'server;command' 500 86400

# PATH mocks are only honored after explicit NEXAWRT_TEST_MODE=1.
mkdir -p "$TMP/production-path/scripts" "$TMP/production-path/hardware-evidence/case" "$TMP/untrusted-bin"
cp "$ROOT_DIR/scripts/run-ax9000-stress-gate.sh" "$TMP/production-path/scripts/"
write_runtime_inputs "$TMP/production-path/hardware-evidence/case"
for tool in date python3 sleep ssh; do
  cat > "$TMP/untrusted-bin/$tool" <<'MOCK'
#!/bin/sh
printf '%s\n' invoked >> "$UNTRUSTED_TOOL_MARKER"
exit 99
MOCK
  chmod +x "$TMP/untrusted-bin/$tool"
done
UNTRUSTED_TOOL_MARKER="$TMP/untrusted-invoked"
export UNTRUSTED_TOOL_MARKER
expect_failure 'production PATH substitution' env PATH="$TMP/untrusted-bin:$PATH" \
  "$TMP/production-path/scripts/run-ax9000-stress-gate.sh" root@127.0.0.1 "$TMP/production-path/hardware-evidence/case" 192.0.2.2 500 86400
[[ ! -e "$UNTRUSTED_TOOL_MARKER" ]] || fail 'production mode executed a PATH-provided clock, sleep, Python, or SSH substitute'

mkdir -p "$TMP/failed/scripts" "$TMP/failed/hardware-evidence/case" "$TMP/fail-bin"
cp "$ROOT_DIR/scripts/run-ax9000-stress-gate.sh" "$ROOT_DIR/scripts/verify-stress-evidence.sh" "$TMP/failed/scripts/"
write_runtime_inputs "$TMP/failed/hardware-evidence/case"
cat > "$TMP/fail-bin/ssh" <<'MOCK'
#!/bin/sh
exit 1
MOCK
chmod +x "$TMP/fail-bin/ssh"
expect_failure 'live runner SSH continuity failure' env NEXAWRT_TEST_MODE=1 PATH="$TMP/fail-bin:$PATH" \
  "$TMP/failed/scripts/run-ax9000-stress-gate.sh" root@192.0.2.1 "$TMP/failed/hardware-evidence/case" 192.0.2.2 500 86400
for leaf in stress-24h.log network-regression.log thermal.log kernel-health.log; do
  [[ -f "$TMP/failed/hardware-evidence/case/$leaf" && ! -L "$TMP/failed/hardware-evidence/case/$leaf" ]] || fail "failed run did not leave regular $leaf"
done
if [[ -s "$TMP/failed/hardware-evidence/case/stress-24h.log" ]]; then
  grep -Fxq 'completed=no' "$TMP/failed/hardware-evidence/case/stress-24h.log" || fail 'failed run committed a non-fail-closed state'
  grep -Fxq 'execution_mode=test' "$TMP/failed/hardware-evidence/case/stress-24h.log" || fail 'test runner did not label incomplete evidence as test mode'
fi
! grep -Fxq 'completed=yes' "$TMP/failed/hardware-evidence/case/stress-24h.log" || fail 'failed run committed completed=yes'
[[ ! -e "$TMP/failed/hardware-evidence/case/stress-gate.txt" && ! -L "$TMP/failed/hardware-evidence/case/stress-gate.txt" ]] || fail 'failed run left a pass gate'

mkdir -p "$TMP/symlink/scripts" "$TMP/symlink/hardware-evidence/case"
cp "$ROOT_DIR/scripts/run-ax9000-stress-gate.sh" "$TMP/symlink/scripts/"
write_runtime_inputs "$TMP/symlink/hardware-evidence/case"
for leaf in stress-24h.log network-regression.log thermal.log kernel-health.log stress-gate.txt; do
  printf 'victim-%s\n' "$leaf" > "$TMP/victim-$leaf"
  ln -s "$TMP/victim-$leaf" "$TMP/symlink/hardware-evidence/case/$leaf"
done
expect_failure 'live runner refuses pre-existing output leaves' \
  "$TMP/symlink/scripts/run-ax9000-stress-gate.sh" root@192.0.2.1 "$TMP/symlink/hardware-evidence/case" 192.0.2.2 500 86400
for leaf in stress-24h.log network-regression.log thermal.log kernel-health.log stress-gate.txt; do
  [[ -L "$TMP/symlink/hardware-evidence/case/$leaf" ]] || fail "runner replaced one-time $leaf symlink"
  grep -Fxq "victim-$leaf" "$TMP/victim-$leaf" || fail "runner modified $leaf symlink victim"
done

mkdir -p "$TMP/symlink-root/scripts" "$TMP/escape"
cp "$ROOT_DIR/scripts/run-ax9000-stress-gate.sh" "$TMP/symlink-root/scripts/"
ln -s "$TMP/escape" "$TMP/symlink-root/hardware-evidence"
mkdir -p "$TMP/escape/case"
expect_failure 'live runner symlinked evidence root' "$TMP/symlink-root/scripts/run-ax9000-stress-gate.sh" root@192.0.2.1 "$TMP/symlink-root/hardware-evidence/case" 192.0.2.2 500 86400

sed -i.bak 's/elapsed_seconds=86400/elapsed_seconds=86399/' "$E/stress-gate.txt"; rm "$E/stress-gate.txt.bak"
expect_failure 'short duration' "$ROOT_DIR/scripts/verify-stress-evidence.sh" "$E"
sed -i.bak 's/elapsed_seconds=86399/elapsed_seconds=86400/' "$E/stress-gate.txt"; rm "$E/stress-gate.txt.bak"
sed -i.bak 's/direction=reverse mbps=850.0 status=pass/direction=reverse mbps=499.0 status=pass/' "$E/network-regression.log"; rm "$E/network-regression.log.bak"
expect_failure 'low throughput' "$ROOT_DIR/scripts/verify-stress-evidence.sh" "$E"
sed -i.bak 's/mbps=499.0/mbps=850.0/' "$E/network-regression.log"; rm "$E/network-regression.log.bak"
sed -i.bak 's/millidegrees=70000/millidegrees=96000/' "$E/thermal.log"; rm "$E/thermal.log.bak"
expect_failure 'over temperature' "$ROOT_DIR/scripts/verify-stress-evidence.sh" "$E"
sed -i.bak 's/millidegrees=96000/millidegrees=70000/' "$E/thermal.log"; rm "$E/thermal.log.bak"

cp "$E/stress-gate.txt" "$TMP/stress-gate.valid"
sed -i.bak "s/session_id=$SESSION/session_id=1111111111111111111111111111111111111111111111111111111111111111/" "$E/stress-gate.txt"; rm "$E/stress-gate.txt.bak"
expect_failure 'spliced stress session' "$ROOT_DIR/scripts/verify-stress-evidence.sh" "$E"
cp "$TMP/stress-gate.valid" "$E/stress-gate.txt"
cp "$E/stress-24h.log" "$TMP/stress-log.valid"
sed -i.bak "s/device_fingerprint_sha256=$FINGERPRINT/device_fingerprint_sha256=2222222222222222222222222222222222222222222222222222222222222222/" "$E/stress-24h.log"; rm "$E/stress-24h.log.bak"
expect_failure 'spliced stress device' "$ROOT_DIR/scripts/verify-stress-evidence.sh" "$E"
cp "$TMP/stress-log.valid" "$E/stress-24h.log"
printf 'unexpected=value\n' >> "$E/stress-gate.txt"
expect_failure 'extra stress schema field' "$ROOT_DIR/scripts/verify-stress-evidence.sh" "$E"
cp "$TMP/stress-gate.valid" "$E/stress-gate.txt"

cp "$E/kernel-health.log" "$TMP/kernel.valid"
sed -i.bak '/^round=24 /d' "$E/kernel-health.log"; rm "$E/kernel-health.log.bak"
expect_failure 'missing kernel health round' "$ROOT_DIR/scripts/verify-stress-evidence.sh" "$E"
cp "$TMP/kernel.valid" "$E/kernel-health.log"
cp "$E/network-regression.log" "$TMP/network.valid"; cp "$E/thermal.log" "$TMP/thermal.valid"; cp "$E/kernel-health.log" "$TMP/kernel.valid"
for file in network-regression.log thermal.log kernel-health.log; do
  sed -i.bak 's/round=24 epoch=182800 monotonic_seconds=132800/round=24 epoch=179200 monotonic_seconds=129200/' "$E/$file"; rm "$E/$file.bak"
done
expect_failure 'non-increasing round timestamps' "$ROOT_DIR/scripts/verify-stress-evidence.sh" "$E"
cp "$TMP/network.valid" "$E/network-regression.log"; cp "$TMP/thermal.valid" "$E/thermal.log"; cp "$TMP/kernel.valid" "$E/kernel-health.log"
for file in network-regression.log thermal.log kernel-health.log; do
  sed -i.bak 's/round=12 epoch=139600 monotonic_seconds=89600/round=12 epoch=145000 monotonic_seconds=95000/' "$E/$file"; rm "$E/$file.bak"
done
expect_failure 'round coverage gap' "$ROOT_DIR/scripts/verify-stress-evidence.sh" "$E"
cp "$TMP/network.valid" "$E/network-regression.log"; cp "$TMP/thermal.valid" "$E/thermal.log"; cp "$TMP/kernel.valid" "$E/kernel-health.log"

sed -i.bak "s/round=12 epoch=139600 monotonic_seconds=89600 boot_id=$BOOT_ID/round=12 epoch=139600 monotonic_seconds=89600 boot_id=$OTHER_BOOT_ID/" "$E/kernel-health.log"; rm "$E/kernel-health.log.bak"
expect_failure 'boot ID switch in evidence' "$ROOT_DIR/scripts/verify-stress-evidence.sh" "$E"
cp "$TMP/kernel.valid" "$E/kernel-health.log"
for file in network-regression.log thermal.log kernel-health.log; do
  sed -i.bak 's/round=12 epoch=139600 monotonic_seconds=89600 boot_id=12345678-1234-4123-8123-123456789abc device_uptime_seconds=49600/round=12 epoch=139600 monotonic_seconds=89600 boot_id=12345678-1234-4123-8123-123456789abc device_uptime_seconds=45000/' "$E/$file"; rm "$E/$file.bak"
done
expect_failure 'device uptime rollback in evidence' "$ROOT_DIR/scripts/verify-stress-evidence.sh" "$E"
cp "$TMP/network.valid" "$E/network-regression.log"; cp "$TMP/thermal.valid" "$E/thermal.log"; cp "$TMP/kernel.valid" "$E/kernel-health.log"

cp -R "$E" "$TMP/test-evidence"
sed -i.bak 's/execution_mode=production/execution_mode=test/' "$TMP/test-evidence/stress-gate.txt"; rm "$TMP/test-evidence/stress-gate.txt.bak"
sed -i.bak 's/execution_mode=production/execution_mode=test/' "$TMP/test-evidence/stress-24h.log"; rm "$TMP/test-evidence/stress-24h.log.bak"
expect_failure 'test-mode evidence in production verifier' "$ROOT_DIR/scripts/verify-stress-evidence.sh" "$TMP/test-evidence"
"$ROOT_DIR/scripts/verify-stress-evidence.sh" --allow-test "$TMP/test-evidence" >/dev/null

make_accelerated_bin() {
  local bin="$1"
  mkdir -p "$bin"
  cat > "$bin/python3" <<'PYTHON'
#!/bin/sh
set -eu
if [ "${1:-}" = -c ] && [ "${2:-}" = 'import time; print(int(time.monotonic()))' ]; then
  value=$(cat "$TEST_MONOTONIC_FILE" 2>/dev/null || printf 0)
  value=$((value + 4000))
  printf '%s\n' "$value" > "$TEST_MONOTONIC_FILE"
  printf '%s\n' "$value"
  exit 0
fi
exec "$REAL_PYTHON3" "$@"
PYTHON
  cat > "$bin/date" <<'DATE'
#!/bin/sh
set -eu
value=$(cat "$TEST_EPOCH_FILE" 2>/dev/null || printf 100000)
value=$((value + 4000))
printf '%s\n' "$value" > "$TEST_EPOCH_FILE"
printf '%s\n' "$value"
DATE
  cat > "$bin/sleep" <<'SLEEP'
#!/bin/sh
exit 0
SLEEP
  cat > "$bin/ssh" <<'SSH'
#!/bin/sh
set -eu
for arg in "$@"; do command=$arg; done
case "$command" in
  *"sh -s --"*)
    cat >/dev/null
    count=$(cat "$TEST_STATE_COUNT_FILE" 2>/dev/null || printf 0)
    count=$((count + 1)); printf '%s\n' "$count" > "$TEST_STATE_COUNT_FILE"
    mono=$(cat "$TEST_MONOTONIC_FILE")
    boot="$TEST_BOOT_ID"
    uptime=$((10000 + mono - 4000))
    if [ "${TEST_STATE_SCENARIO:-normal}" = boot-switch ] && [ "$count" -ge 2 ]; then boot="$TEST_OTHER_BOOT_ID"; fi
    if [ "${TEST_STATE_SCENARIO:-normal}" = uptime-regress ] && [ "$count" -ge 2 ]; then uptime=9000; fi
    printf 'boot_id=%s\nuptime_seconds=%s\niperf3_path=/test/iperf3\n' "$boot" "$uptime"
    ;;
  dmesg) printf 'healthy kernel\n' ;;
  *'/sys/class/thermal/'*) printf 'thermal_zone0:cpu 70000\n' ;;
  *iperf3*) printf '{"end":{"sum_received":{"bits_per_second":900000000}}}\n' ;;
  *) exit 1 ;;
esac
SSH
  chmod +x "$bin/"*
}
REAL_PYTHON3="$(command -v python3)"
export REAL_PYTHON3 TEST_MONOTONIC_FILE TEST_EPOCH_FILE TEST_STATE_COUNT_FILE TEST_BOOT_ID TEST_OTHER_BOOT_ID TEST_STATE_SCENARIO
TEST_BOOT_ID="$BOOT_ID"; TEST_OTHER_BOOT_ID="$OTHER_BOOT_ID"

# Runner must fail closed if the device reboots or its uptime regresses between rounds.
for scenario in boot-switch uptime-regress; do
  case_root="$TMP/runner-$scenario"
  mkdir -p "$case_root/scripts" "$case_root/hardware-evidence/case"
  cp "$ROOT_DIR/scripts/run-ax9000-stress-gate.sh" "$ROOT_DIR/scripts/verify-stress-evidence.sh" "$case_root/scripts/"
  write_runtime_inputs "$case_root/hardware-evidence/case"
  make_accelerated_bin "$case_root/bin"
  TEST_MONOTONIC_FILE="$case_root/mono"; TEST_EPOCH_FILE="$case_root/epoch"; TEST_STATE_COUNT_FILE="$case_root/state-count"; TEST_STATE_SCENARIO="$scenario"
  expect_failure "runner $scenario" env NEXAWRT_TEST_MODE=1 PATH="$case_root/bin:$PATH" \
    "$case_root/scripts/run-ax9000-stress-gate.sh" router "$case_root/hardware-evidence/case" 192.0.2.2 500 86400
  grep -Fxq 'completed=no' "$case_root/hardware-evidence/case/stress-24h.log" || fail "$scenario runner failure committed completed=yes"
  [[ ! -e "$case_root/hardware-evidence/case/stress-gate.txt" ]] || fail "$scenario runner failure committed a pass gate"
done

# Exercise two-phase commit under explicit test mode. The temporary verifier sees completed=yes,
# deliberately rejects it, and the final evidence must remain completed=no.
mkdir -p "$TMP/atomic/scripts" "$TMP/atomic/hardware-evidence/case"
cp "$ROOT_DIR/scripts/run-ax9000-stress-gate.sh" "$TMP/atomic/scripts/"
write_runtime_inputs "$TMP/atomic/hardware-evidence/case"
cat > "$TMP/atomic/scripts/verify-stress-evidence.sh" <<'VERIFY'
#!/bin/sh
set -eu
[ "$1" = --allow-test ]
case "$2" in */.stress-verify.*) ;; *) exit 91;; esac
grep -Fxq 'execution_mode=test' "$2/stress-24h.log"
grep -Fxq 'completed=yes' "$2/stress-24h.log"
parent=${2%/.stress-verify.*}
grep -Fxq 'completed=no' "$parent/stress-24h.log"
[ ! -e "$parent/stress-gate.txt" ]
exit 92
VERIFY
chmod +x "$TMP/atomic/scripts/verify-stress-evidence.sh"
make_accelerated_bin "$TMP/atomic-bin"
TEST_MONOTONIC_FILE="$TMP/atomic-mono"; TEST_EPOCH_FILE="$TMP/atomic-epoch"; TEST_STATE_COUNT_FILE="$TMP/atomic-state-count"; TEST_STATE_SCENARIO=normal
expect_failure 'temporary stress verification rejection' env NEXAWRT_TEST_MODE=1 PATH="$TMP/atomic-bin:$PATH" NEXAWRT_STRESS_ROUND_INTERVAL_SECONDS=60 NEXAWRT_IPERF_SECONDS=10 \
  "$TMP/atomic/scripts/run-ax9000-stress-gate.sh" router "$TMP/atomic/hardware-evidence/case" 192.0.2.2 500 86400
grep -Fxq 'completed=no' "$TMP/atomic/hardware-evidence/case/stress-24h.log" || fail 'temporary verification failure committed completed=yes'
grep -Fxq 'execution_mode=test' "$TMP/atomic/hardware-evidence/case/stress-24h.log" || fail 'atomic test evidence was not labeled test mode'
[[ ! -e "$TMP/atomic/hardware-evidence/case/stress-gate.txt" ]] || fail 'temporary verification failure committed a pass gate'

echo '24h stress evidence binds production/test mode, immutable boot ID, monotonic device uptime, trusted production tools, and verified two-phase completion: OK'
