#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../manifests/upstream.lock
source "$ROOT_DIR/manifests/upstream.lock"
OPENWRT_REPO="${OPENWRT_REPO_OVERRIDE:-$OPENWRT_REPO}"
WORK_DIR="${WORK_DIR:-$ROOT_DIR/.work/openwrt}"
WITH_FEEDS=1
CLEAN=0

usage() {
  cat <<USAGE
Usage: $0 [--clean] [--no-feeds]

Clone the pinned OpenWrt source, reset it to the locked commit, apply the
single-large-UBI patches, copy the seed config/files, and optionally install
all pinned official feeds.
USAGE
}

while (($#)); do
  case "$1" in
    --clean) CLEAN=1 ;;
    --no-feeds) WITH_FEEDS=0 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [[ "$(uname -s)" == Darwin && "$WITH_FEEDS" == 1 && "${ALLOW_UNSUPPORTED_HOST:-0}" != 1 ]]; then
  cat >&2 <<'MSG'
On macOS, use --no-feeds for patch/static validation and use the GitHub Actions
Linux workflow for a full preparation/build. OpenWrt requires newer GNU tools
and a case-sensitive filesystem. Set ALLOW_UNSUPPORTED_HOST=1 only after you
have provided those requirements yourself.
MSG
  exit 1
fi

if ((CLEAN)); then
  rm -rf "$WORK_DIR"
fi

if [[ ! -d "$WORK_DIR/.git" ]]; then
  rm -rf "$WORK_DIR"
  mkdir -p "$WORK_DIR"
  git -C "$WORK_DIR" init -q
  git -C "$WORK_DIR" remote add origin "$OPENWRT_REPO"
fi

cd "$WORK_DIR"
origin_url="$(git remote get-url origin)"
if [[ "$origin_url" != "$OPENWRT_REPO" ]]; then
  echo "Refusing unexpected OpenWrt remote: $origin_url" >&2
  exit 1
fi

fetched=0
for attempt in 1 2 3; do
  if GIT_TERMINAL_PROMPT=0 git -c http.version=HTTP/1.1 fetch --depth 1 origin \
    "refs/tags/$OPENWRT_TAG:refs/tags/$OPENWRT_TAG"; then
    fetched=1
    break
  fi
  echo "OpenWrt fetch attempt $attempt failed; retrying..." >&2
  sleep $((attempt * 3))
done
((fetched == 1)) || { echo "Unable to fetch pinned OpenWrt source" >&2; exit 1; }

git checkout --detach --force "$OPENWRT_COMMIT"
git reset --hard "$OPENWRT_COMMIT"
git clean -fd

if [[ "$(git rev-parse HEAD)" != "$OPENWRT_COMMIT" ]]; then
  echo "OpenWrt commit verification failed" >&2
  exit 1
fi

for patch in "$ROOT_DIR"/patches/[0-9][0-9][0-9]-*.patch; do
  git apply --check "$patch"
  git apply "$patch"
done

rm -rf files
mkdir -p files
rsync -a "$ROOT_DIR/files/" files/
cp "$ROOT_DIR/configs/ax9000-single-ubi.config" .config

if ((WITH_FEEDS)); then
  feeds_updated=0
  for attempt in 1 2 3; do
    if ./scripts/feeds update -a; then
      feeds_updated=1
      break
    fi
    echo "Feed update attempt $attempt failed; retrying..." >&2
    sleep $((attempt * 3))
  done
  ((feeds_updated == 1)) || { echo "Unable to update pinned feeds" >&2; exit 1; }
  ./scripts/feeds install -a
  # Feed indexing may normalize .config while feed symbols are not yet visible.
  # Restore the locked seed after all packages are installed, then resolve it.
  cp "$ROOT_DIR/configs/ax9000-single-ubi.config" .config
  make defconfig
fi

"$ROOT_DIR/scripts/validate.sh" --source "$WORK_DIR"
printf 'Prepared OpenWrt %s at %s\n' "$OPENWRT_COMMIT" "$WORK_DIR"
