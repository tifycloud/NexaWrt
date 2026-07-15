#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TARGET="${1:-}"
OUTPUT_RAW="${2:-}"
PHASE="${3:-}"
fail() { echo "production state collection failed: $*" >&2; exit 1; }
[[ -n "$TARGET" && -n "$OUTPUT_RAW" && -n "$PHASE" ]] || fail "usage: $0 SSH_TARGET EVIDENCE_DIRECTORY before|after"
[[ "$TARGET" =~ ^[A-Za-z0-9._%+@:-]+$ && "$TARGET" != -* ]] || fail "unsafe SSH target"
case "$PHASE" in before|after) ;; *) fail "phase must be before or after" ;; esac
command -v ssh >/dev/null || fail "ssh is required"
command -v python3 >/dev/null || fail "python3 is required"

OUTPUT_DIR="$(python3 - "$ROOT_DIR" "$OUTPUT_RAW" <<'PY'
import os, pathlib, sys
root = pathlib.Path(sys.argv[1]).resolve(strict=True)
allowed = root / "hardware-evidence"
if os.path.lexists(allowed) and (allowed.is_symlink() or not allowed.is_dir()): raise SystemExit(1)
raw = pathlib.Path(os.path.abspath(sys.argv[2]))
try: relative = raw.relative_to(allowed)
except ValueError: raise SystemExit(1)
if not relative.parts: raise SystemExit(1)
current = allowed
for part in relative.parts:
    current /= part
    if os.path.lexists(current) and current.is_symlink(): raise SystemExit(1)
resolved=raw.resolve(strict=False)
if not resolved.is_dir(): raise SystemExit(1)
print(resolved)
PY
)" || fail "evidence directory must be below $ROOT_DIR/hardware-evidence without symlinks"
[[ -s "$OUTPUT_DIR/SESSION.txt" && ! -L "$OUTPUT_DIR/SESSION.txt" ]] || fail "safe SESSION.txt is required"
session_id="$(python3 - "$OUTPUT_DIR/SESSION.txt" <<'PY'
import pathlib, re, sys
path=pathlib.Path(sys.argv[1])
lines=path.read_text(encoding="utf-8", errors="strict").splitlines()
if len(lines) != 1: raise SystemExit(1)
match=re.fullmatch(r"session_id=([0-9a-f]{64})", lines[0])
if not match: raise SystemExit(1)
print(match.group(1))
PY
)" || fail "SESSION.txt schema is invalid"

capture_files=(
  "production-capture-$PHASE.txt"
  "production-cmdline-$PHASE.txt"
  "mtd-layout-$PHASE.txt"
  "uboot-printenv-$PHASE.txt"
  "production-identity-$PHASE.txt"
)
for file in "${capture_files[@]}"; do
  [[ ! -e "$OUTPUT_DIR/$file" && ! -L "$OUTPUT_DIR/$file" ]] ||
    fail "phase evidence already exists and cannot be overwritten: $file"
done
if [[ "$PHASE" == after ]]; then
  [[ -s "$OUTPUT_DIR/production-capture-before.txt" && ! -L "$OUTPUT_DIR/production-capture-before.txt" ]] ||
    fail "before capture is required before collecting after state"
fi

challenge="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
if [[ "$PHASE" == after ]] && grep -Fxq "challenge=$challenge" "$OUTPUT_DIR/production-capture-before.txt"; then
  fail "random capture challenge unexpectedly repeated"
fi
archive="$(mktemp "$OUTPUT_DIR/.production-capture-$PHASE.XXXXXX")"
trap 'rm -f -- "${archive:-}"' EXIT
remote_command="sh -s -- '$session_id' '$PHASE' '$challenge'"
if ! ssh -o BatchMode=yes -o ConnectTimeout=15 "$TARGET" "$remote_command" > "$archive" <<'REMOTE'; then
set -eu
session_id="$1"
phase="$2"
challenge="$3"
case "$phase" in before|after) ;; *) exit 1 ;; esac
printf '%s\n' "$session_id" | grep -Eq '^[0-9a-f]{64}$'
printf '%s\n' "$challenge" | grep -Eq '^[0-9a-f]{64}$'
command -v fw_printenv >/dev/null
command -v sha256sum >/dev/null
command -v tar >/dev/null
umask 077
capture_dir="${TMPDIR:-/tmp}/nexawrt-production-capture.$$"
rm -rf -- "$capture_dir"
mkdir "$capture_dir"
trap 'rm -rf -- "$capture_dir"' EXIT HUP INT TERM
cat /proc/cmdline > "$capture_dir/production-cmdline.txt"
cat /proc/mtd > "$capture_dir/mtd-layout.txt"
fw_printenv > "$capture_dir/uboot-printenv.txt"
board_name=$(cat /tmp/sysinfo/board_name)
ethaddr=$(fw_printenv -n ethaddr | tr 'A-F' 'a-f')
kernel=$(uname -r)
. /etc/openwrt_release
release=${DISTRIB_RELEASE:-}
boot_id=$(cat /proc/sys/kernel/random/boot_id)
uptime=$(cut -d. -f1 /proc/uptime)
collected_epoch=$(date +%s)
printf 'board_name=%s\nkernel=%s\nrelease=%s\n' "$board_name" "$kernel" "$release" > "$capture_dir/production-identity.txt"
device_fingerprint=$(printf '%s\nethaddr=%s\n' "$board_name" "$ethaddr" | sha256sum | awk '{print $1}')
file_sha() { sha256sum "$capture_dir/$1" | awk '{print $1}'; }
cat > "$capture_dir/production-capture.txt" <<META
schema=2
session_id=$session_id
challenge=$challenge
phase=$phase
collected_epoch=$collected_epoch
uptime_seconds=$uptime
boot_id=$boot_id
board_name=$board_name
ethaddr=$ethaddr
device_fingerprint_sha256=$device_fingerprint
production_cmdline_sha256=$(file_sha production-cmdline.txt)
mtd_layout_sha256=$(file_sha mtd-layout.txt)
uboot_printenv_sha256=$(file_sha uboot-printenv.txt)
production_identity_sha256=$(file_sha production-identity.txt)
META
tar -C "$capture_dir" -cf - \
  production-capture.txt production-cmdline.txt mtd-layout.txt uboot-printenv.txt production-identity.txt
REMOTE
  rm -f -- "$archive"
  fail "single-shot SSH production capture failed"
fi
[[ -s "$archive" && -f "$archive" && ! -L "$archive" ]] || fail "remote production capture archive is empty or unsafe"
chmod 0600 "$archive"

python3 - "$archive" "$OUTPUT_DIR" "$PHASE" "$session_id" "$challenge" <<'PY' || fail "single-shot production capture is malformed, replayed, or could not be committed exclusively"
import hashlib, io, os, pathlib, re, tarfile, sys
archive=pathlib.Path(sys.argv[1])
root=pathlib.Path(sys.argv[2])
phase=sys.argv[3]
expected_session=sys.argv[4]
expected_challenge=sys.argv[5]
member_names={
    "production-capture.txt",
    "production-cmdline.txt",
    "mtd-layout.txt",
    "uboot-printenv.txt",
    "production-identity.txt",
}
with tarfile.open(archive, mode="r:") as bundle:
    members=bundle.getmembers()
    if {member.name for member in members} != member_names or len(members) != len(member_names):
        raise SystemExit("capture archive member set mismatch")
    payload={}
    for member in members:
        if not member.isfile() or member.issym() or member.islnk() or member.size <= 0 or member.size > 4 * 1024 * 1024:
            raise SystemExit("unsafe capture archive member")
        handle=bundle.extractfile(member)
        if handle is None: raise SystemExit("capture member cannot be read")
        data=handle.read()
        if len(data) != member.size or b"\0" in data: raise SystemExit("capture member is malformed")
        data.decode("utf-8", errors="strict")
        payload[member.name]=data

def kv(data):
    values={}
    for line in data.decode("utf-8").splitlines():
        if not line or "=" not in line: raise SystemExit("capture metadata syntax mismatch")
        key,value=line.split("=",1)
        if not key or not value or key in values: raise SystemExit("capture metadata duplicate/empty field")
        values[key]=value
    return values
meta=kv(payload["production-capture.txt"])
expected_keys={
    "schema","session_id","challenge","phase","collected_epoch","uptime_seconds","boot_id",
    "board_name","ethaddr","device_fingerprint_sha256","production_cmdline_sha256",
    "mtd_layout_sha256","uboot_printenv_sha256","production_identity_sha256",
}
if set(meta) != expected_keys or meta["schema"] != "2": raise SystemExit("capture metadata schema mismatch")
if meta["session_id"] != expected_session or meta["phase"] != phase or meta["challenge"] != expected_challenge:
    raise SystemExit("capture request binding mismatch")
if not re.fullmatch(r"[0-9a-f]{64}", meta["challenge"]): raise SystemExit("capture challenge is invalid")
if not re.fullmatch(r"[1-9][0-9]*", meta["collected_epoch"]): raise SystemExit("capture epoch is invalid")
if not re.fullmatch(r"[0-9]+", meta["uptime_seconds"]): raise SystemExit("capture uptime is invalid")
if not re.fullmatch(r"[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}", meta["boot_id"]):
    raise SystemExit("capture boot ID is invalid")
if meta["board_name"] != "xiaomi,ax9000": raise SystemExit("capture board is invalid")
if not re.fullmatch(r"[0-9a-f]{2}(?::[0-9a-f]{2}){5}", meta["ethaddr"]): raise SystemExit("capture ethaddr is invalid")
fingerprint=hashlib.sha256(f'{meta["board_name"]}\nethaddr={meta["ethaddr"]}\n'.encode()).hexdigest()
if meta["device_fingerprint_sha256"] != fingerprint: raise SystemExit("capture device fingerprint mismatch")
for archive_name, key in (
    ("production-cmdline.txt", "production_cmdline_sha256"),
    ("mtd-layout.txt", "mtd_layout_sha256"),
    ("uboot-printenv.txt", "uboot_printenv_sha256"),
    ("production-identity.txt", "production_identity_sha256"),
):
    if hashlib.sha256(payload[archive_name]).hexdigest() != meta[key]:
        raise SystemExit("capture payload digest mismatch")
destinations={
    "production-cmdline.txt": f"production-cmdline-{phase}.txt",
    "mtd-layout.txt": f"mtd-layout-{phase}.txt",
    "uboot-printenv.txt": f"uboot-printenv-{phase}.txt",
    "production-identity.txt": f"production-identity-{phase}.txt",
    "production-capture.txt": f"production-capture-{phase}.txt",
}
created=[]
def exclusive_write(path, data):
    flags=os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"): flags |= os.O_NOFOLLOW
    fd=os.open(path, flags, 0o600)
    created.append(path)
    try:
        view=memoryview(data)
        while view:
            written=os.write(fd, view)
            if written <= 0: raise OSError("short write")
            view=view[written:]
        os.fsync(fd)
    finally:
        os.close(fd)
try:
    for source in ("production-cmdline.txt","mtd-layout.txt","uboot-printenv.txt","production-identity.txt","production-capture.txt"):
        exclusive_write(root/destinations[source], payload[source])
    directory_fd=os.open(root, os.O_RDONLY)
    try: os.fsync(directory_fd)
    finally: os.close(directory_fd)
except BaseException:
    for path in reversed(created):
        try: pathlib.Path(path).unlink()
        except FileNotFoundError: pass
    raise
PY
rm -f -- "$archive"
archive=
trap - EXIT
printf 'Production state (%s) collected in one challenge-bound SSH transaction: %s\n' "$PHASE" "$OUTPUT_DIR"
