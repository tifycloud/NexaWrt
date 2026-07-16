#!/usr/bin/env bash
set -euo pipefail

EVIDENCE_RAW="${1:-}"
MODE="${2:-write}"
fail() { echo "post-reboot verification failed: $*" >&2; exit 1; }
[[ -n "$EVIDENCE_RAW" ]] || fail "usage: $0 EVIDENCE_DIRECTORY [--check-only]"
case "$MODE" in write|--check-only) ;; *) fail "unknown mode: $MODE" ;; esac
EVIDENCE_DIR="$(python3 - "$EVIDENCE_RAW" <<'PY'
import pathlib, sys
raw=pathlib.Path(sys.argv[1])
if raw.is_symlink(): raise SystemExit(1)
resolved=raw.resolve(strict=True)
if not resolved.is_dir(): raise SystemExit(1)
print(resolved)
PY
)" || fail "evidence directory is missing or unsafe"
required=(
  SESSION.txt
  production-capture-before.txt production-capture-after.txt
  production-cmdline-before.txt production-cmdline-after.txt
  mtd-layout-before.txt mtd-layout-after.txt
  uboot-printenv-before.txt uboot-printenv-after.txt
  production-identity-before.txt production-identity-after.txt
)
for file in "${required[@]}"; do
  [[ -s "$EVIDENCE_DIR/$file" && ! -L "$EVIDENCE_DIR/$file" ]] || fail "required state file is missing, empty, or a symlink: $file"
done
identity="$(python3 - "$EVIDENCE_DIR" <<'PY'
import hashlib, pathlib, re, shlex, sys
root=pathlib.Path(sys.argv[1])

def read_bytes(name):
    data=root.joinpath(name).read_bytes()
    if not data or b"\0" in data: raise SystemExit(f"empty or binary state file: {name}")
    data.decode("utf-8", errors="strict")
    return data

def read(name):
    return read_bytes(name).decode("utf-8").replace("\r\n", "\n").strip()

def kv(name, expected=None):
    values={}
    for line in read(name).splitlines():
        if not line or "=" not in line: raise SystemExit(f"invalid key/value line in {name}")
        key,value=line.split("=",1)
        if not key or not value or key in values: raise SystemExit(f"duplicate/empty field in {name}: {key}")
        values[key]=value
    if expected is not None and set(values) != expected: raise SystemExit(f"schema mismatch: {name}")
    return values

session_lines=read("SESSION.txt").splitlines()
if len(session_lines) != 1: raise SystemExit("SESSION.txt schema mismatch")
session_match=re.fullmatch(r"session_id=([0-9a-f]{64})", session_lines[0])
if not session_match: raise SystemExit("SESSION.txt is invalid")
session_id=session_match.group(1)
metadata_keys={
    "schema","session_id","challenge","phase","collected_epoch","uptime_seconds","boot_id",
    "board_name","ethaddr","device_fingerprint_sha256","production_cmdline_sha256",
    "mtd_layout_sha256","uboot_printenv_sha256","production_identity_sha256",
}

def capture(phase):
    values=kv(f"production-capture-{phase}.txt", metadata_keys)
    if values["schema"] != "2" or values["session_id"] != session_id or values["phase"] != phase:
        raise SystemExit(f"capture binding mismatch: {phase}")
    if not re.fullmatch(r"[0-9a-f]{64}", values["challenge"]): raise SystemExit(f"invalid challenge: {phase}")
    if not re.fullmatch(r"[1-9][0-9]*", values["collected_epoch"]): raise SystemExit(f"invalid epoch: {phase}")
    if not re.fullmatch(r"[0-9]+", values["uptime_seconds"]): raise SystemExit(f"invalid uptime: {phase}")
    if not re.fullmatch(r"[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}", values["boot_id"]):
        raise SystemExit(f"invalid boot ID: {phase}")
    if values["board_name"] != "xiaomi,ax9000": raise SystemExit(f"unexpected board: {phase}")
    if not re.fullmatch(r"[0-9a-f]{2}(?::[0-9a-f]{2}){5}", values["ethaddr"]): raise SystemExit(f"invalid ethaddr: {phase}")
    fingerprint=hashlib.sha256(f'{values["board_name"]}\nethaddr={values["ethaddr"]}\n'.encode()).hexdigest()
    if values["device_fingerprint_sha256"] != fingerprint: raise SystemExit(f"device fingerprint mismatch: {phase}")
    for filename,key in (
        (f"production-cmdline-{phase}.txt", "production_cmdline_sha256"),
        (f"mtd-layout-{phase}.txt", "mtd_layout_sha256"),
        (f"uboot-printenv-{phase}.txt", "uboot_printenv_sha256"),
        (f"production-identity-{phase}.txt", "production_identity_sha256"),
    ):
        if hashlib.sha256(read_bytes(filename)).hexdigest() != values[key]:
            raise SystemExit(f"capture payload digest mismatch: {filename}")
    return values

before=capture("before")
after=capture("after")
if before["challenge"] == after["challenge"]: raise SystemExit("capture challenge replay detected")
if before["boot_id"] == after["boot_id"]: raise SystemExit("no reboot observed between production captures")
if int(after["collected_epoch"]) <= int(before["collected_epoch"]): raise SystemExit("capture chronology is invalid")
for key in ("session_id","board_name","ethaddr","device_fingerprint_sha256"):
    if before[key] != after[key]: raise SystemExit(f"capture device/session changed: {key}")

def cmdline(name):
    value=read(name)
    tokens=shlex.split(value)
    roots=[token for token in tokens if token.startswith("root=")]
    if not tokens or len(roots) != 1 or not roots[0].split("=",1)[1]: raise SystemExit(f"invalid production cmdline: {name}")
    root_device=roots[0].split("=",1)[1]
    if root_device.startswith("/dev/ram"): raise SystemExit(f"RAM root is not a production root: {name}")
    if root_device != "/dev/ubiblock0_1": raise SystemExit(f"unexpected production root device: {name}")
    if any(token.startswith("ubi.mtd=") and not token.split("=",1)[1] for token in tokens):
        raise SystemExit(f"invalid production UBI selector: {name}")
    return tokens

def mtd(name):
    lines=[line.strip() for line in read(name).splitlines() if line.strip()]
    if not lines or lines[0] != "dev:    size   erasesize  name": raise SystemExit(f"invalid MTD header: {name}")
    pattern=re.compile(r'^mtd([0-9]+): ([0-9a-fA-F]{8}) ([0-9a-fA-F]{8}) "([^"]+)"$')
    parsed=[]
    for line in lines[1:]:
        match=pattern.fullmatch(line)
        if not match: raise SystemExit(f"invalid MTD line in {name}: {line}")
        parsed.append((int(match.group(1)),match.group(2).lower(),match.group(3).lower(),match.group(4)))
    if not parsed or len({item[0] for item in parsed}) != len(parsed) or len({item[3] for item in parsed}) != len(parsed):
        raise SystemExit(f"duplicate or empty MTD layout: {name}")
    return parsed

def env(name):
    values={}
    for line in read(name).splitlines():
        line=line.strip()
        if not line or line.startswith("#"): continue
        if "=" not in line: raise SystemExit(f"invalid U-Boot environment line in {name}: {line}")
        key,value=line.split("=",1)
        if not key or key in values: raise SystemExit(f"duplicate U-Boot environment key in {name}: {key}")
        values[key]=value
    if not values: raise SystemExit(f"empty U-Boot environment: {name}")
    return values

def production_identity(name):
    values=kv(name)
    if set(values) != {"board_name","kernel","release"} or values["board_name"] != "xiaomi,ax9000":
        raise SystemExit(f"unexpected production identity in {name}")
    return values

if cmdline("production-cmdline-before.txt") != cmdline("production-cmdline-after.txt"):
    raise SystemExit("production kernel command line changed")
if mtd("mtd-layout-before.txt") != mtd("mtd-layout-after.txt"): raise SystemExit("MTD layout changed")
if env("uboot-printenv-before.txt") != env("uboot-printenv-after.txt"): raise SystemExit("U-Boot environment changed")
if production_identity("production-identity-before.txt") != production_identity("production-identity-after.txt"):
    raise SystemExit("production identity changed")
print(session_id + "\t" + before["device_fingerprint_sha256"])
PY
)" || fail "production state changed, was replayed, or is malformed"
IFS=$'\t' read -r session_id device_fingerprint <<<"$identity"
if [[ "$MODE" == write ]]; then
  python3 - "$EVIDENCE_DIR/post-reboot-gate.txt" "$session_id" "$device_fingerprint" <<'PY' || fail "post-reboot gate already exists or cannot be committed exclusively"
import os, sys
path=sys.argv[1]
data=(
    "reboot_to_production=pass\n"
    f"session_id={sys.argv[2]}\n"
    f"device_fingerprint_sha256={sys.argv[3]}\n"
    "mtd_layout_unchanged=pass\n"
    "uboot_env_unchanged=pass\n"
).encode()
flags=os.O_WRONLY | os.O_CREAT | os.O_EXCL
if hasattr(os, "O_NOFOLLOW"): flags |= os.O_NOFOLLOW
fd=os.open(path, flags, 0o600)
try:
    view=memoryview(data)
    while view:
        written=os.write(fd, view)
        if written <= 0: raise OSError("short write")
        view=view[written:]
    os.fsync(fd)
finally:
    os.close(fd)
PY
  echo "Post-reboot production recovery gate passed: $EVIDENCE_DIR/post-reboot-gate.txt"
else
  echo "Post-reboot production recovery state is unchanged and challenge-bound"
fi
