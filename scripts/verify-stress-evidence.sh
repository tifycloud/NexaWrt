#!/bin/bash
set -euo pipefail

ALLOW_TEST=no
if [[ "${1:-}" == --allow-test ]]; then
  ALLOW_TEST=yes
  shift
fi
EVIDENCE_RAW="${1:-}"
[[ $# -eq 1 && -n "$EVIDENCE_RAW" ]] || { echo "stress evidence verification failed: usage: $0 [--allow-test] EVIDENCE_DIRECTORY" >&2; exit 1; }
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
fail() { echo "stress evidence verification failed: $*" >&2; exit 1; }

trusted_python() {
  local path=/usr/bin/python3 metadata uid mode
  [[ -x /usr/bin/stat && ! -L /usr/bin/stat && -f "$path" && -x "$path" && ! -L "$path" ]] || return 1
  if metadata="$(/usr/bin/stat -f '%u %Lp' "$path" 2>/dev/null)"; then :
  elif metadata="$(/usr/bin/stat -c '%u %a' "$path" 2>/dev/null)"; then :
  else return 1
  fi
  read -r uid mode <<<"$metadata"
  [[ "$uid" == 0 && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  (( (8#$mode & 022) == 0 )) || return 1
  printf '%s\n' "$path"
}
PYTHON_BIN="$(trusted_python)" || fail "trusted root-owned /usr/bin/python3 is required"

EVIDENCE_DIR="$("$PYTHON_BIN" - "$EVIDENCE_RAW" <<'PY'
import pathlib, sys
raw=pathlib.Path(sys.argv[1])
if raw.is_symlink(): raise SystemExit(1)
resolved=raw.resolve(strict=True)
if not resolved.is_dir(): raise SystemExit(1)
print(resolved)
PY
)" || fail "evidence directory is missing or unsafe"
for file in SESSION.txt runtime-gate.txt stress-gate.txt stress-24h.log network-regression.log thermal.log kernel-health.log; do
  [[ -s "$EVIDENCE_DIR/$file" && ! -L "$EVIDENCE_DIR/$file" ]] || fail "required stress evidence is missing, empty, or a symlink: $file"
done
"$PYTHON_BIN" - "$EVIDENCE_DIR" "$ALLOW_TEST" <<'PY' || fail "24-hour stress evidence is incomplete or malformed"
import pathlib, re, sys
root=pathlib.Path(sys.argv[1])
allow_test=sys.argv[2]=="yes"
clock_tolerance=300
boot_pattern=re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}")

def kv_file(name):
    values={}
    for line in root.joinpath(name).read_text(encoding="utf-8", errors="strict").splitlines():
        if not line or "=" not in line: raise SystemExit(f"invalid {name} line")
        key,value=line.split("=",1)
        if not key or value == "" or key in values: raise SystemExit(f"duplicate/empty {name} key: {key}")
        values[key]=value
    return values

def integer(values,key,minimum=0):
    value=values.get(key,"")
    if not re.fullmatch(r"[0-9]+",value): raise SystemExit(f"invalid integer {key}")
    result=int(value)
    if result<minimum: raise SystemExit(f"{key} below minimum")
    return result

gate=kv_file("stress-gate.txt")
expected_gate_keys={
    "stress_24h","execution_mode","session_id","device_fingerprint_sha256","device_boot_id",
    "started_device_uptime_seconds","ended_device_uptime_seconds","network_regression","panic_oops",
    "thermal_throttle","elapsed_seconds","network_min_mbps","network_rounds",
    "thermal_limit_millidegrees","thermal_max_millidegrees","round_interval_seconds","iperf_seconds",
}
if set(gate) != expected_gate_keys: raise SystemExit("stress gate schema mismatch")
for key,value in {"stress_24h":"pass","network_regression":"pass","panic_oops":"none","thermal_throttle":"none"}.items():
    if gate.get(key)!=value: raise SystemExit(f"gate marker mismatch: {key}")
execution_mode=gate.get("execution_mode")
if execution_mode not in {"production","test"}: raise SystemExit("invalid stress execution mode")
if execution_mode=="test" and not allow_test: raise SystemExit("test-mode stress evidence is not production eligible")
elapsed=integer(gate,"elapsed_seconds",86400)
min_mbps=integer(gate,"network_min_mbps",1)
rounds=integer(gate,"network_rounds",24)
thermal_limit=integer(gate,"thermal_limit_millidegrees",1)
thermal_max=integer(gate,"thermal_max_millidegrees",0)
round_interval=integer(gate,"round_interval_seconds",60)
iperf_seconds=integer(gate,"iperf_seconds",10)
if round_interval>3600 or iperf_seconds>300: raise SystemExit("stress timing policy exceeds production bounds")
if thermal_max>thermal_limit: raise SystemExit("thermal maximum exceeds limit")

stress=kv_file("stress-24h.log")
expected_stress_keys={
    "schema","execution_mode","session_id","device_fingerprint_sha256","device_boot_id",
    "started_device_uptime_seconds","ended_device_uptime_seconds","started_epoch","ended_epoch",
    "started_monotonic_seconds","ended_monotonic_seconds","elapsed_seconds","completed","rounds",
    "round_interval_seconds","iperf_seconds","ssh_failures","iperf_failures","panic_oops_matches",
    "thermal_throttle_matches",
}
if set(stress) != expected_stress_keys: raise SystemExit("stress log schema mismatch")
if stress.get("schema")!="3" or stress.get("completed")!="yes": raise SystemExit("stress run is incomplete")
if stress.get("execution_mode")!=execution_mode: raise SystemExit("stress execution mode mismatch")
session_lines=root.joinpath("SESSION.txt").read_text(encoding="utf-8", errors="strict").splitlines()
if len(session_lines) != 1: raise SystemExit("SESSION.txt schema mismatch")
session_match=re.fullmatch(r"session_id=([0-9a-f]{64})", session_lines[0])
if not session_match: raise SystemExit("SESSION.txt is invalid")
session_id=session_match.group(1)
runtime=kv_file("runtime-gate.txt")
fingerprint=runtime.get("device_fingerprint_sha256", "")
if not re.fullmatch(r"[0-9a-f]{64}", fingerprint): raise SystemExit("runtime fingerprint is invalid")
for values in (gate,stress):
    if values.get("session_id") != session_id or values.get("device_fingerprint_sha256") != fingerprint:
        raise SystemExit("stress evidence belongs to a different session or device")
boot_id=stress.get("device_boot_id","")
if not boot_pattern.fullmatch(boot_id) or gate.get("device_boot_id")!=boot_id:
    raise SystemExit("stress boot ID is invalid or inconsistent")
started_device_uptime=integer(stress,"started_device_uptime_seconds",0)
ended_device_uptime=integer(stress,"ended_device_uptime_seconds",started_device_uptime)
if integer(gate,"started_device_uptime_seconds",0)!=started_device_uptime or integer(gate,"ended_device_uptime_seconds",0)!=ended_device_uptime:
    raise SystemExit("stress gate device uptime does not bind to stress log")
started=integer(stress,"started_epoch",1)
ended=integer(stress,"ended_epoch",started)
started_monotonic=integer(stress,"started_monotonic_seconds",1)
ended_monotonic=integer(stress,"ended_monotonic_seconds",started_monotonic)
logged_elapsed=integer(stress,"elapsed_seconds",86400)
device_elapsed=ended_device_uptime-started_device_uptime
if ended_monotonic-started_monotonic != logged_elapsed or logged_elapsed != elapsed:
    raise SystemExit("stress monotonic elapsed time is inconsistent")
if ended < started or abs((ended-started)-logged_elapsed)>clock_tolerance:
    raise SystemExit("wall clock changed excessively during stress run")
if device_elapsed<86400 or abs(device_elapsed-logged_elapsed)>clock_tolerance:
    raise SystemExit("device uptime does not corroborate 24-hour stress duration")
if integer(stress,"rounds",24)!=rounds: raise SystemExit("stress round count mismatch")
if integer(stress,"round_interval_seconds",60)!=round_interval or integer(stress,"iperf_seconds",10)!=iperf_seconds:
    raise SystemExit("stress timing policy mismatch")
for key in ("ssh_failures","iperf_failures","panic_oops_matches","thermal_throttle_matches"):
    if integer(stress,key,0)!=0: raise SystemExit(f"stress failure counter is nonzero: {key}")

round_prefix=(
    r"^round=([0-9]+) epoch=([0-9]+) monotonic_seconds=([0-9]+) "
    r"boot_id=([0-9a-f-]+) device_uptime_seconds=([0-9]+) "
)
network_pattern=re.compile(round_prefix + r"direction=(forward|reverse) mbps=([0-9]+(?:\.[0-9]+)?) status=(pass|fail)$")
network={}
round_state={}
for line in root.joinpath("network-regression.log").read_text(encoding="utf-8", errors="strict").splitlines():
    match=network_pattern.fullmatch(line)
    if not match: raise SystemExit(f"malformed network result: {line}")
    number=int(match.group(1)); epoch=int(match.group(2)); mono=int(match.group(3))
    line_boot=match.group(4); uptime=int(match.group(5)); direction=match.group(6)
    mbps=float(match.group(7)); status=match.group(8)
    if line_boot!=boot_id: raise SystemExit(f"network boot ID changed at round {number}")
    key=(number,direction)
    if key in network: raise SystemExit(f"duplicate network result: {key}")
    if status!="pass" or mbps<min_mbps: raise SystemExit(f"network result below gate: {key}")
    state=(epoch,mono,uptime)
    if number in round_state and round_state[number]!=state: raise SystemExit(f"network state disagrees within round {number}")
    round_state[number]=state
    network[key]=mbps
expected={(number,direction) for number in range(1,rounds+1) for direction in ("forward","reverse")}
if set(network)!=expected or set(round_state)!=set(range(1,rounds+1)):
    raise SystemExit("network rounds are incomplete")

max_gap=round_interval + 2*iperf_seconds + 120
previous_epoch=None
previous_mono=None
previous_uptime=None
for number in range(1,rounds+1):
    epoch,mono,uptime=round_state[number]
    if not (started <= epoch <= ended and started_monotonic <= mono <= ended_monotonic):
        raise SystemExit(f"round timestamp is outside stress interval: {number}")
    if abs((epoch-started)-(mono-started_monotonic))>clock_tolerance:
        raise SystemExit(f"wall/monotonic clocks disagree at round {number}")
    if abs((uptime-started_device_uptime)-(mono-started_monotonic))>clock_tolerance:
        raise SystemExit(f"device uptime/local monotonic progress disagree at round {number}")
    if previous_epoch is not None:
        if epoch<=previous_epoch or mono<=previous_mono: raise SystemExit("round timestamps are not strictly increasing")
        if uptime<=previous_uptime: raise SystemExit("device uptime is not strictly increasing between rounds")
        if mono-previous_mono>max_gap or uptime-previous_uptime>max_gap:
            raise SystemExit("round coverage gap exceeds policy")
    previous_epoch,previous_mono,previous_uptime=epoch,mono,uptime
if round_state[1][1]-started_monotonic>max_gap or round_state[1][2]-started_device_uptime>max_gap:
    raise SystemExit("first round does not cover stress start")
if ended_monotonic-round_state[rounds][1]>max_gap or ended_device_uptime-round_state[rounds][2]>max_gap:
    raise SystemExit("last round does not cover stress end")

thermal_pattern=re.compile(round_prefix + r"zone=([^\s]+) millidegrees=([0-9]+)$")
thermal_rounds={number:0 for number in range(1,rounds+1)}
samples=[]
for line in root.joinpath("thermal.log").read_text(encoding="utf-8", errors="strict").splitlines():
    match=thermal_pattern.fullmatch(line)
    if not match: raise SystemExit(f"malformed thermal result: {line}")
    number=int(match.group(1)); state=(int(match.group(2)),int(match.group(3)),int(match.group(5)))
    if match.group(4)!=boot_id or number not in round_state or round_state[number]!=state:
        raise SystemExit("thermal state does not bind to its boot and round")
    value=int(match.group(7))
    if value>thermal_limit: raise SystemExit("thermal sample exceeds limit")
    thermal_rounds[number]+=1
    samples.append(value)
if any(count<1 for count in thermal_rounds.values()) or max(samples,default=-1)!=thermal_max:
    raise SystemExit("thermal samples are incomplete or maximum mismatches")

kernel_pattern=re.compile(
    round_prefix + r"panic_oops_matches=([0-9]+) thermal_throttle_matches=([0-9]+) status=(pass|fail)$"
)
kernel_seen=set()
for line in root.joinpath("kernel-health.log").read_text(encoding="utf-8", errors="strict").splitlines():
    match=kernel_pattern.fullmatch(line)
    if not match: raise SystemExit(f"malformed kernel health result: {line}")
    number=int(match.group(1)); state=(int(match.group(2)),int(match.group(3)),int(match.group(5)))
    if number in kernel_seen or number not in round_state: raise SystemExit("duplicate or unknown kernel health round")
    if match.group(4)!=boot_id or round_state[number]!=state:
        raise SystemExit("kernel health state does not bind to its boot and round")
    if int(match.group(6))!=0 or int(match.group(7))!=0 or match.group(8)!="pass":
        raise SystemExit("kernel health round failed")
    kernel_seen.add(number)
if kernel_seen != set(range(1,rounds+1)): raise SystemExit("kernel health rounds are incomplete")
PY
if [[ "$ALLOW_TEST" == yes ]]; then
  echo 'Stress evidence gate passed (test evidence explicitly allowed): timing, boot continuity, device uptime, network, kernel health, and thermal policy verified'
else
  echo 'Stress evidence gate passed: production timing, boot continuity, device uptime, network, kernel health, and thermal policy verified'
fi
