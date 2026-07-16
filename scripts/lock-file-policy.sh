#!/usr/bin/env bash
set -euo pipefail

nexawrt_validate_lock_file() {
  local lock_file="$1"
  local schema="$2"
  python3 - "$lock_file" "$schema" <<'PY'
import pathlib
import re
import stat
import sys

path = pathlib.Path(sys.argv[1])
schema = sys.argv[2]
try:
    mode = path.lstat().st_mode
except FileNotFoundError:
    raise SystemExit(f"lock file is missing: {path}")
if not stat.S_ISREG(mode) or stat.S_ISLNK(mode):
    raise SystemExit(f"lock file is not a safe regular file: {path}")

schemas = {
    "upstream": {
        "OPENWRT_REPO", "OPENWRT_TAG", "OPENWRT_COMMIT", "LAYOUT_ID",
        "ROOTFS_MTD_OFFSET_HEX", "ROOTFS_MTD_SIZE_HEX", "ROOTFS_MTD_ERASE_SIZE_HEX",
    },
    "apk-signing": {"NEXAWRT_APK_SIGNING_PRODUCTION_PUBLIC_SHA256"},
    "nss": {
        "NSS_OPENWRT_REPO", "NSS_OPENWRT_BRANCH", "NSS_OPENWRT_COMMIT",
        "NSS_PACKAGES_FEED", "NSS_PACKAGES_REPO", "NSS_PACKAGES_COMMIT",
        "NSS_SQM_FEED", "NSS_SQM_REPO", "NSS_SQM_COMMIT",
    },
}
if schema not in schemas:
    raise SystemExit(f"unknown lock schema: {schema}")
assignment = re.compile(r'([A-Z][A-Z0-9_]*)="([^"\\]*)"')
values = {}
for number, raw in enumerate(path.read_text(encoding="utf-8", errors="strict").splitlines(), 1):
    line = raw.strip()
    if not line or line.startswith("#"):
        continue
    match = assignment.fullmatch(line)
    if not match:
        raise SystemExit(f"lock file contains non-declarative syntax at line {number}: {path}")
    key, value = match.groups()
    if key in values:
        raise SystemExit(f"lock file contains duplicate key {key}: {path}")
    values[key] = value
expected = schemas[schema]
if set(values) != expected:
    missing = sorted(expected - set(values))
    extra = sorted(set(values) - expected)
    raise SystemExit(f"lock file schema mismatch: missing={missing}, extra={extra}: {path}")

def require(key, pattern):
    if not re.fullmatch(pattern, values[key]):
        raise SystemExit(f"lock file has invalid {key}: {path}")

commit_keys = [key for key in values if key.endswith("_COMMIT")]
for key in commit_keys:
    require(key, r"[0-9a-f]{40}")
for key in [key for key in values if key.endswith("_REPO")]:
    require(key, r"https://[A-Za-z0-9._~:/?#\[\]@!$&'()*+,;=%-]+")
for key in [key for key in values if key.endswith("_HEX")]:
    require(key, r"0x[0-9a-f]{8}")
if schema == "apk-signing":
    require("NEXAWRT_APK_SIGNING_PRODUCTION_PUBLIC_SHA256", r"UNPROVISIONED|[0-9a-f]{64}")
elif schema == "upstream":
    require("OPENWRT_TAG", r"[A-Za-z0-9._/-]+")
    require("LAYOUT_ID", r"[A-Za-z0-9._-]+")
else:
    require("NSS_OPENWRT_BRANCH", r"[A-Za-z0-9._/-]+")
    require("NSS_PACKAGES_FEED", r"[a-z0-9_]+")
    require("NSS_SQM_FEED", r"[a-z0-9_]+")
PY
}
