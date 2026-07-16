#!/bin/bash
set -euo pipefail

case "${NEXAWRT_TEST_MODE:-0}" in
  0|'') EXECUTION_MODE='production' ;;
  1) EXECUTION_MODE='test' ;;
  *) echo 'AX9000 stress gate failed: NEXAWRT_TEST_MODE must be unset, 0, or 1' >&2; exit 1 ;;
esac
if [[ "$EXECUTION_MODE" == production ]]; then
  PATH=/usr/bin:/bin:/usr/sbin:/sbin
  export PATH
fi

ROOT_DIR="$(cd "${BASH_SOURCE[0]%/*}/.." && pwd -P)"
TARGET="${1:-}"
EVIDENCE_RAW="${2:-}"
IPERF_SERVER="${3:-}"
MIN_MBPS="${4:-}"
DURATION_SECONDS="${5:-86400}"
THERMAL_LIMIT="${6:-95000}"
ROUND_INTERVAL_SECONDS="${NEXAWRT_STRESS_ROUND_INTERVAL_SECONDS:-60}"
IPERF_SECONDS="${NEXAWRT_IPERF_SECONDS:-30}"
CLOCK_TOLERANCE_SECONDS=300

fail() { echo "AX9000 stress gate failed: $*" >&2; exit 1; }
usage() { fail "usage: $0 SSH_TARGET EVIDENCE_DIRECTORY IPERF3_SERVER MIN_MBPS [DURATION_SECONDS>=86400] [THERMAL_LIMIT_MILLIDEGREES]"; }
[[ -n "$TARGET" && -n "$EVIDENCE_RAW" && -n "$IPERF_SERVER" && -n "$MIN_MBPS" ]] || usage
[[ "$TARGET" =~ ^[A-Za-z0-9._%+@:-]+$ && "$TARGET" != -* ]] || fail "unsafe SSH target"
[[ "$IPERF_SERVER" =~ ^[A-Za-z0-9._:-]+$ && "$IPERF_SERVER" != -* ]] || fail "unsafe iperf3 server"
for value_name in MIN_MBPS DURATION_SECONDS THERMAL_LIMIT ROUND_INTERVAL_SECONDS IPERF_SECONDS; do
  value="${!value_name}"
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || fail "$value_name must be a positive integer"
done
(( DURATION_SECONDS >= 86400 )) || fail "the production stress gate cannot be shorter than 86400 seconds"
(( ROUND_INTERVAL_SECONDS >= 60 && ROUND_INTERVAL_SECONDS <= 3600 )) || fail "round interval must be between 60 and 3600 seconds"
(( IPERF_SECONDS >= 10 && IPERF_SECONDS <= 300 )) || fail "iperf duration must be between 10 and 300 seconds"

trusted_mode() {
  local path="$1" metadata uid mode
  [[ "$path" == /* && -f "$path" && -x "$path" && ! -L "$path" ]] || return 1
  if metadata="$(/usr/bin/stat -f '%u %Lp' "$path" 2>/dev/null)"; then :
  elif metadata="$(/usr/bin/stat -c '%u %a' "$path" 2>/dev/null)"; then :
  else return 1
  fi
  read -r uid mode <<<"$metadata"
  [[ "$uid" == 0 && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  (( (8#$mode & 022) == 0 ))
}
select_production_tool() {
  local candidate
  for candidate in "$@"; do
    if trusted_mode "$candidate"; then printf '%s\n' "$candidate"; return 0; fi
  done
  return 1
}
select_test_tool() {
  command -v "$1"
}

if [[ "$EXECUTION_MODE" == production ]]; then
  [[ -x /usr/bin/stat && ! -L /usr/bin/stat ]] || fail "trusted /usr/bin/stat is required"
  PYTHON_BIN="$(select_production_tool /usr/bin/python3)" || fail "trusted root-owned python3 is required at /usr/bin/python3"
  DATE_BIN="$(select_production_tool /bin/date /usr/bin/date)" || fail "trusted root-owned date is required"
  SLEEP_BIN="$(select_production_tool /bin/sleep /usr/bin/sleep)" || fail "trusted root-owned sleep is required"
  SSH_BIN="$(select_production_tool /usr/bin/ssh)" || fail "trusted root-owned ssh is required at /usr/bin/ssh"
else
  PYTHON_BIN="$(select_test_tool python3)" || fail "python3 is required"
  DATE_BIN="$(select_test_tool date)" || fail "date is required"
  SLEEP_BIN="$(select_test_tool sleep)" || fail "sleep is required"
  SSH_BIN="$(select_test_tool ssh)" || fail "ssh is required"
fi

EVIDENCE_DIR="$("$PYTHON_BIN" - "$ROOT_DIR" "$EVIDENCE_RAW" <<'PY'
import os, pathlib, sys
root=pathlib.Path(sys.argv[1]).resolve(strict=True)
allowed=root / "hardware-evidence"
if os.path.lexists(allowed) and (allowed.is_symlink() or not allowed.is_dir()): raise SystemExit(1)
raw=pathlib.Path(os.path.abspath(sys.argv[2]))
try: relative=raw.relative_to(allowed)
except ValueError: raise SystemExit(1)
if not relative.parts: raise SystemExit(1)
current=allowed
for part in relative.parts:
    current /= part
    if os.path.lexists(current) and current.is_symlink(): raise SystemExit(1)
resolved=raw.resolve(strict=False)
if not resolved.is_dir(): raise SystemExit(1)
print(resolved)
PY
)" || fail "evidence must be an existing non-symlink directory below $ROOT_DIR/hardware-evidence"

runtime_gate="$EVIDENCE_DIR/runtime-gate.txt"
[[ -s "$runtime_gate" && ! -L "$runtime_gate" ]] || fail "verified runtime-gate.txt is required before stress testing"
for marker in root=/dev/ram0 persistent_ubi_attached=no persistent_mounts=no all_mtd_partitions_readonly=yes raw_mtd_write_probe=blocked; do
  grep -Fxq "$marker" "$runtime_gate" || fail "runtime gate marker missing: $marker"
done
identity="$("$PYTHON_BIN" - "$runtime_gate" "$EVIDENCE_DIR/SESSION.txt" <<'PY'
import pathlib, re, sys
runtime=pathlib.Path(sys.argv[1]); session_file=pathlib.Path(sys.argv[2])
if runtime.is_symlink() or session_file.is_symlink(): raise SystemExit(1)
values={}
for line in runtime.read_text(encoding="utf-8", errors="strict").splitlines():
    if "=" not in line: raise SystemExit(1)
    key,value=line.split("=",1)
    if not key or key in values: raise SystemExit(1)
    values[key]=value
lines=session_file.read_text(encoding="utf-8", errors="strict").splitlines()
if len(lines) != 1: raise SystemExit(1)
match=re.fullmatch(r"session_id=([0-9a-f]{64})", lines[0])
if not match or values.get("session_id") != match.group(1): raise SystemExit(1)
fingerprint=values.get("device_fingerprint_sha256", "")
if not re.fullmatch(r"[0-9a-f]{64}", fingerprint): raise SystemExit(1)
print(values["session_id"] + "\t" + fingerprint)
PY
)" || fail "runtime session/device identity is missing, duplicated, or inconsistent"
IFS=$'\t' read -r session_id device_fingerprint <<<"$identity"

stress_log="$EVIDENCE_DIR/stress-24h.log"
network_log="$EVIDENCE_DIR/network-regression.log"
thermal_log="$EVIDENCE_DIR/thermal.log"
kernel_log="$EVIDENCE_DIR/kernel-health.log"
stress_gate="$EVIDENCE_DIR/stress-gate.txt"
for output in "$stress_log" "$network_log" "$thermal_log" "$kernel_log" "$stress_gate"; do
  [[ ! -e "$output" && ! -L "$output" ]] || fail "stress evidence already exists and cannot be overwritten: $(basename "$output")"
done

safe_create_file() {
  "$PYTHON_BIN" - "$1" <<'PY'
import os, sys
flags=os.O_WRONLY | os.O_CREAT | os.O_EXCL
if hasattr(os, "O_NOFOLLOW"): flags |= os.O_NOFOLLOW
fd=os.open(sys.argv[1], flags, 0o600)
os.close(fd)
PY
}
safe_append_line() {
  "$PYTHON_BIN" - "$1" "$2" <<'PY'
import os, stat, sys
flags=os.O_WRONLY | os.O_APPEND
if hasattr(os, "O_NOFOLLOW"): flags |= os.O_NOFOLLOW
fd=os.open(sys.argv[1], flags)
try:
    if not stat.S_ISREG(os.fstat(fd).st_mode): raise SystemExit(1)
    view=memoryview((sys.argv[2] + "\n").encode())
    while view:
        written=os.write(fd, view)
        if written <= 0: raise SystemExit(1)
        view=view[written:]
    os.fsync(fd)
finally:
    os.close(fd)
PY
}
atomic_replace() {
  "$PYTHON_BIN" - "$1" "$2" <<'PY'
import os, pathlib, sys
source=pathlib.Path(sys.argv[1]); destination=pathlib.Path(sys.argv[2])
if not source.is_file() or source.is_symlink(): raise SystemExit(1)
if os.path.lexists(destination) and destination.is_dir() and not destination.is_symlink(): raise SystemExit(1)
os.replace(source, destination)
dirfd=os.open(destination.parent, os.O_RDONLY)
try: os.fsync(dirfd)
finally: os.close(dirfd)
PY
}
safe_remove_regular() {
  "$PYTHON_BIN" - "$1" <<'PY'
import os, stat, sys
path=sys.argv[1]
if not os.path.lexists(path): raise SystemExit(0)
mode=os.lstat(path).st_mode
if stat.S_ISREG(mode): os.unlink(path)
PY
}
for output in "$stress_log" "$network_log" "$thermal_log" "$kernel_log"; do safe_create_file "$output"; done

monotonic_seconds() { "$PYTHON_BIN" -c 'import time; print(int(time.monotonic()))'; }
query_runtime_state() {
  local raw temporary
  temporary="$(mktemp "${TMPDIR:-/tmp}/nexawrt-runtime-state.XXXXXX")" || return 1
  if ! "$SSH_BIN" -o BatchMode=yes -o ConnectTimeout=15 "$TARGET" "sh -s -- '$session_id' '$device_fingerprint'" >"$temporary" <<'REMOTE'
set -eu
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
expected_session="$1"
expected_fingerprint="$2"
cmdline=$(cat /proc/cmdline)
root_count=0; root_total=0; session_count=0; session_total=0
for token in $cmdline; do
  case "$token" in root=*) root_total=$((root_total + 1));; esac
  [ "$token" = root=/dev/ram0 ] && root_count=$((root_count + 1))
  case "$token" in nexawrt.session=*) session_total=$((session_total + 1));; esac
  [ "$token" = "nexawrt.session=$expected_session" ] && session_count=$((session_count + 1))
done
[ "$root_count" -eq 1 ] && [ "$root_total" -eq 1 ]
[ "$session_count" -eq 1 ] && [ "$session_total" -eq 1 ]
! grep -Eq "[[:space:]](ubifs|jffs2|overlay)[[:space:]]" /proc/mounts
set -- /sys/class/ubi/ubi[0-9]*
[ "$1" = "/sys/class/ubi/ubi[0-9]*" ]
ethaddr=$(fw_printenv -n ethaddr 2>/dev/null | tr 'A-F' 'a-f')
printf '%s\n' "$ethaddr" | grep -Eq '^[0-9a-f]{2}(:[0-9a-f]{2}){5}$'
actual_fingerprint=$(printf 'xiaomi,ax9000\nethaddr=%s\n' "$ethaddr" | sha256sum | awk '{print $1}')
[ "$actual_fingerprint" = "$expected_fingerprint" ]
boot_id=$(cat /proc/sys/kernel/random/boot_id)
printf '%s\n' "$boot_id" | grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
uptime_raw=$(cut -d' ' -f1 /proc/uptime)
uptime_seconds=${uptime_raw%%.*}
printf '%s\n' "$uptime_seconds" | grep -Eq '^[0-9]+$'
iperf3_path=/usr/bin/iperf3
[ -f "$iperf3_path" ] && [ -x "$iperf3_path" ] && [ ! -L "$iperf3_path" ]
set -- $(stat -c '%u %a' "$iperf3_path")
[ "$1" -eq 0 ]
mode=$2
[ $((0$mode & 022)) -eq 0 ]
printf 'boot_id=%s\nuptime_seconds=%s\niperf3_path=%s\n' "$boot_id" "$uptime_seconds" "$iperf3_path"
REMOTE
  then
    rm -f -- "$temporary"
    return 1
  fi
  raw="$(cat "$temporary")"
  rm -f -- "$temporary"
  "$PYTHON_BIN" - "$raw" <<'PY'
import re, sys
lines=sys.argv[1].splitlines()
if len(lines)!=3: raise SystemExit(1)
values={}
for line in lines:
    if "=" not in line: raise SystemExit(1)
    key,value=line.split("=",1)
    if key in values or not value: raise SystemExit(1)
    values[key]=value
if set(values)!={"boot_id","uptime_seconds","iperf3_path"}: raise SystemExit(1)
if not re.fullmatch(r"[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}", values["boot_id"]): raise SystemExit(1)
if not re.fullmatch(r"[0-9]+", values["uptime_seconds"]): raise SystemExit(1)
if values["iperf3_path"] != "/usr/bin/iperf3" and not values["iperf3_path"].startswith("/test/"): raise SystemExit(1)
print(values["boot_id"] + "\t" + values["uptime_seconds"] + "\t" + values["iperf3_path"])
PY
}

started_epoch="$("$DATE_BIN" +%s)"
started_monotonic="$(monotonic_seconds)"
initial_state="$(query_runtime_state)" || fail "cannot establish initial RAM-only runtime, boot ID, uptime, and trusted remote iperf3"
IFS=$'\t' read -r device_boot_id started_device_uptime remote_iperf3 <<<"$initial_state"
[[ "$EXECUTION_MODE" == test || "$remote_iperf3" == /usr/bin/iperf3 ]] || fail "production mode requires /usr/bin/iperf3"
rounds=0
ssh_failures=0
iperf_failures=0
panic_oops_matches=0
thermal_throttle_matches=0
thermal_max=0
last_round_device_uptime=-1
ended_device_uptime="$started_device_uptime"
final_committed=no
verification_dir=

render_state() {
  local destination="$1" completion="$2" end_epoch="$3" end_monotonic="$4" end_uptime="$5" elapsed
  elapsed=$((end_monotonic - started_monotonic))
  cat > "$destination" <<LOG
schema=3
execution_mode=$EXECUTION_MODE
session_id=$session_id
device_fingerprint_sha256=$device_fingerprint
device_boot_id=$device_boot_id
started_device_uptime_seconds=$started_device_uptime
ended_device_uptime_seconds=$end_uptime
started_epoch=$started_epoch
ended_epoch=$end_epoch
started_monotonic_seconds=$started_monotonic
ended_monotonic_seconds=$end_monotonic
elapsed_seconds=$elapsed
completed=$completion
rounds=$rounds
round_interval_seconds=$ROUND_INTERVAL_SECONDS
iperf_seconds=$IPERF_SECONDS
ssh_failures=$ssh_failures
iperf_failures=$iperf_failures
panic_oops_matches=$panic_oops_matches
thermal_throttle_matches=$thermal_throttle_matches
LOG
  chmod 0600 "$destination"
}
write_progress() {
  local now_epoch now_monotonic temporary
  now_epoch="$("$DATE_BIN" +%s)"
  now_monotonic="$(monotonic_seconds)"
  temporary="$(mktemp "$EVIDENCE_DIR/.stress-progress.XXXXXX")"
  render_state "$temporary" no "$now_epoch" "$now_monotonic" "$ended_device_uptime"
  atomic_replace "$temporary" "$stress_log"
}
on_exit() {
  local status=$?
  trap - EXIT INT TERM
  if [[ "$final_committed" != yes ]]; then
    write_progress >/dev/null 2>&1 || true
    safe_remove_regular "$stress_gate" >/dev/null 2>&1 || true
  fi
  [[ -z "$verification_dir" ]] || rm -rf -- "$verification_dir"
  exit "$status"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
write_progress

validate_round_state() {
  local state="$1" progress device_progress drift
  IFS=$'\t' read -r round_boot_id round_device_uptime round_iperf3 <<<"$state"
  [[ "$round_boot_id" == "$device_boot_id" ]] || fail "device boot ID changed during stress run"
  [[ "$round_iperf3" == "$remote_iperf3" ]] || fail "remote iperf3 identity changed during stress run"
  (( round_device_uptime >= started_device_uptime )) || fail "device uptime predates stress start"
  if (( last_round_device_uptime >= 0 )); then
    (( round_device_uptime > last_round_device_uptime )) || fail "device uptime did not strictly increase between rounds"
  fi
  progress=$((round_monotonic - started_monotonic))
  device_progress=$((round_device_uptime - started_device_uptime))
  drift=$((device_progress - progress)); (( drift < 0 )) && drift=$((-drift))
  (( drift <= CLOCK_TOLERANCE_SECONDS )) || fail "device uptime and trusted local monotonic clock diverged"
  ended_device_uptime="$round_device_uptime"
  last_round_device_uptime="$round_device_uptime"
}
collect_kernel_health() {
  local dmesg_text crash_count throttle_count status
  if ! dmesg_text="$("$SSH_BIN" -o BatchMode=yes -o ConnectTimeout=15 "$TARGET" 'dmesg')"; then
    ssh_failures=$((ssh_failures + 1)); write_progress; fail "cannot collect kernel log"
  fi
  crash_count="$(printf '%s\n' "$dmesg_text" | grep -Eic 'kernel panic|oops:|BUG:|Call trace:|watchdog.*lockup' || true)"
  throttle_count="$(printf '%s\n' "$dmesg_text" | grep -Eic 'thermal.*(thrott|critical|shutdown)|over.?temperature|temperature.*critical' || true)"
  panic_oops_matches=$((panic_oops_matches + crash_count))
  thermal_throttle_matches=$((thermal_throttle_matches + throttle_count))
  status=pass
  (( crash_count == 0 && throttle_count == 0 )) || status=fail
  safe_append_line "$kernel_log" "round=$rounds epoch=$round_epoch monotonic_seconds=$round_monotonic boot_id=$device_boot_id device_uptime_seconds=$round_device_uptime panic_oops_matches=$crash_count thermal_throttle_matches=$throttle_count status=$status"
  (( crash_count == 0 )) || { write_progress; fail "kernel panic/oops evidence detected"; }
  (( throttle_count == 0 )) || { write_progress; fail "thermal throttling/critical evidence detected"; }
}
collect_thermal() {
  local output found=0 zone value
  if ! output="$("$SSH_BIN" -o BatchMode=yes -o ConnectTimeout=15 "$TARGET" '
set -eu
found=0
for path in /sys/class/thermal/thermal_zone*; do
  [ -r "$path/temp" ] || continue
  zone=${path##*/}; type=$(cat "$path/type" 2>/dev/null || printf unknown); temp=$(cat "$path/temp")
  printf "%s:%s %s\n" "$zone" "$type" "$temp"; found=1
done
[ "$found" -eq 1 ]
')"; then
    ssh_failures=$((ssh_failures + 1)); write_progress; fail "cannot collect thermal sensors"
  fi
  while IFS=' ' read -r zone value; do
    [[ "$zone" =~ ^[A-Za-z0-9_.:-]+$ && "$value" =~ ^[0-9]+$ ]] || fail "malformed thermal sample"
    safe_append_line "$thermal_log" "round=$rounds epoch=$round_epoch monotonic_seconds=$round_monotonic boot_id=$device_boot_id device_uptime_seconds=$round_device_uptime zone=$zone millidegrees=$value"
    (( value > thermal_max )) && thermal_max=$value
    (( value <= THERMAL_LIMIT )) || { write_progress; fail "thermal sample exceeds $THERMAL_LIMIT millidegrees"; }
    found=1
  done <<< "$output"
  (( found == 1 )) || fail "no thermal sample returned"
}
run_iperf() {
  local direction="$1" reverse_flag="$2" json mbps status=pass
  if ! json="$("$SSH_BIN" -o BatchMode=yes -o ConnectTimeout=15 "$TARGET" "'$remote_iperf3' -J -c '$IPERF_SERVER' -t '$IPERF_SECONDS' -P 4 $reverse_flag")"; then
    iperf_failures=$((iperf_failures + 1)); status=fail; mbps=0.0
  elif ! mbps="$("$PYTHON_BIN" -c '
import json, sys
try:
    data=json.load(sys.stdin)
    if data.get("error"): raise ValueError(data["error"])
    end=data["end"]
    summary=end.get("sum_received") or end.get("sum") or end.get("sum_sent")
    value=float(summary["bits_per_second"])/1_000_000
    if value < 0: raise ValueError("negative throughput")
    print(f"{value:.1f}")
except Exception as exc:
    print(exc, file=sys.stderr); raise SystemExit(1)
' <<< "$json")"; then
    iperf_failures=$((iperf_failures + 1)); status=fail; mbps=0.0
  fi
  if ! "$PYTHON_BIN" - "$mbps" "$MIN_MBPS" <<'PY'
import sys
raise SystemExit(0 if float(sys.argv[1]) >= int(sys.argv[2]) else 1)
PY
  then status=fail; fi
  safe_append_line "$network_log" "round=$rounds epoch=$round_epoch monotonic_seconds=$round_monotonic boot_id=$device_boot_id device_uptime_seconds=$round_device_uptime direction=$direction mbps=$mbps status=$status"
  [[ "$status" == pass ]] || { write_progress; fail "$direction throughput failed or fell below ${MIN_MBPS} Mbps"; }
}

echo "Starting fail-closed AX9000 stress gate in $EXECUTION_MODE mode for at least $DURATION_SECONDS seconds; interruption leaves completed=no and no pass gate."
while :; do
  rounds=$((rounds + 1))
  if (( rounds == 1 )); then
    round_started="$started_monotonic"
    round_monotonic="$started_monotonic"
    round_epoch="$started_epoch"
    round_state="$initial_state"
  else
    round_started="$(monotonic_seconds)"
    round_monotonic="$round_started"
    round_epoch="$("$DATE_BIN" +%s)"
    if ! round_state="$(query_runtime_state)"; then
      ssh_failures=$((ssh_failures + 1)); write_progress; fail "RAM-only runtime continuity check failed"
    fi
  fi
  validate_round_state "$round_state"
  collect_kernel_health
  collect_thermal
  run_iperf forward ''
  run_iperf reverse '-R'
  write_progress
  now="$(monotonic_seconds)"
  elapsed=$((now - started_monotonic))
  (( elapsed >= DURATION_SECONDS && rounds >= 24 )) && break
  next_round=$((round_started + ROUND_INTERVAL_SECONDS))
  remaining=$((DURATION_SECONDS - elapsed))
  sleep_for=$((next_round - now))
  (( sleep_for < 1 )) && sleep_for=1
  (( remaining > 0 && sleep_for > remaining )) && sleep_for=$remaining
  "$SLEEP_BIN" "$sleep_for"
done

ended_monotonic="$(monotonic_seconds)"
ended_epoch="$("$DATE_BIN" +%s)"
final_state="$(query_runtime_state)" || fail "cannot verify final device boot ID and uptime"
IFS=$'\t' read -r final_boot_id final_device_uptime final_iperf3 <<<"$final_state"
[[ "$final_boot_id" == "$device_boot_id" ]] || fail "device boot ID changed before stress completion"
[[ "$final_iperf3" == "$remote_iperf3" ]] || fail "remote iperf3 identity changed before stress completion"
(( final_device_uptime >= last_round_device_uptime )) || fail "final device uptime regressed"
ended_device_uptime="$final_device_uptime"
elapsed=$((ended_monotonic - started_monotonic))
device_elapsed=$((ended_device_uptime - started_device_uptime))
drift=$((device_elapsed - elapsed)); (( drift < 0 )) && drift=$((-drift))
(( drift <= CLOCK_TOLERANCE_SECONDS )) || fail "final device uptime does not corroborate trusted local elapsed time"
(( elapsed >= 86400 && device_elapsed >= 86400 && rounds >= 24 )) || fail "duration, device uptime, or network round minimum was not met"
verification_dir="$(mktemp -d "$EVIDENCE_DIR/.stress-verify.XXXXXX")"
"$PYTHON_BIN" - "$EVIDENCE_DIR" "$verification_dir" <<'PY'
import os, pathlib, stat, sys
source=pathlib.Path(sys.argv[1]); destination=pathlib.Path(sys.argv[2])
for name in ("SESSION.txt","runtime-gate.txt","network-regression.log","thermal.log","kernel-health.log"):
    src=source/name; dst=destination/name
    flags=os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"): flags |= os.O_NOFOLLOW
    infd=os.open(src, flags)
    try:
        if not stat.S_ISREG(os.fstat(infd).st_mode): raise SystemExit(1)
        outflags=os.O_WRONLY | os.O_CREAT | os.O_EXCL
        if hasattr(os, "O_NOFOLLOW"): outflags |= os.O_NOFOLLOW
        outfd=os.open(dst, outflags, 0o600)
        try:
            while True:
                data=os.read(infd, 1024*1024)
                if not data: break
                view=memoryview(data)
                while view:
                    written=os.write(outfd, view)
                    if written <= 0: raise OSError("short write")
                    view=view[written:]
            os.fsync(outfd)
        finally: os.close(outfd)
    finally: os.close(infd)
PY
render_state "$verification_dir/stress-24h.log" yes "$ended_epoch" "$ended_monotonic" "$ended_device_uptime"
cat > "$verification_dir/stress-gate.txt" <<GATE
stress_24h=pass
execution_mode=$EXECUTION_MODE
session_id=$session_id
device_fingerprint_sha256=$device_fingerprint
device_boot_id=$device_boot_id
started_device_uptime_seconds=$started_device_uptime
ended_device_uptime_seconds=$ended_device_uptime
network_regression=pass
panic_oops=none
thermal_throttle=none
elapsed_seconds=$elapsed
network_min_mbps=$MIN_MBPS
network_rounds=$rounds
thermal_limit_millidegrees=$THERMAL_LIMIT
thermal_max_millidegrees=$thermal_max
round_interval_seconds=$ROUND_INTERVAL_SECONDS
iperf_seconds=$IPERF_SECONDS
GATE
chmod 0600 "$verification_dir/stress-gate.txt"
verify_args=("$verification_dir")
[[ "$EXECUTION_MODE" == production ]] || verify_args=(--allow-test "$verification_dir")
"$ROOT_DIR/scripts/verify-stress-evidence.sh" "${verify_args[@]}"
atomic_replace "$verification_dir/stress-24h.log" "$stress_log"
atomic_replace "$verification_dir/stress-gate.txt" "$stress_gate"
final_committed=yes
trap - EXIT INT TERM
rm -rf -- "$verification_dir"
verification_dir=
printf 'AX9000 24-hour %s stress gate passed: %s\n' "$EXECUTION_MODE" "$EVIDENCE_DIR"
