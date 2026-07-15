#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../manifests/upstream.lock
source "$ROOT_DIR/manifests/upstream.lock"
NEXAWRT_FLAVOR="${NEXAWRT_FLAVOR:-official}"
WITH_FEEDS=1
CLEAN=0

case "$NEXAWRT_FLAVOR" in
  official)
    SOURCE_REPO="${OPENWRT_REPO_OVERRIDE:-$OPENWRT_REPO}"
    SOURCE_COMMIT="$OPENWRT_COMMIT"
    SOURCE_LABEL="$OPENWRT_TAG"
    SEED_CONFIG="$ROOT_DIR/configs/ax9000-single-ubi.config"
    DEFAULT_WORK_DIR="$ROOT_DIR/.work/openwrt"
    ;;
  nss)
    # Keep the stable official path independent from the experimental NSS lock.
    # shellcheck source=../manifests/nss.lock
    source "$ROOT_DIR/manifests/nss.lock"
    SOURCE_REPO="${OPENWRT_REPO_OVERRIDE:-$NSS_OPENWRT_REPO}"
    SOURCE_COMMIT="$NSS_OPENWRT_COMMIT"
    SOURCE_LABEL="$NSS_OPENWRT_BRANCH"
    SEED_CONFIG="$ROOT_DIR/configs/ax9000-single-ubi-nss.config"
    DEFAULT_WORK_DIR="$ROOT_DIR/.work/openwrt-nss"
    ;;
  *)
    echo "Unsupported NEXAWRT_FLAVOR: $NEXAWRT_FLAVOR (expected official or nss)" >&2
    exit 2
    ;;
esac
WORK_DIR="${WORK_DIR:-$DEFAULT_WORK_DIR}"

usage() {
  cat <<USAGE
Usage: $0 [--clean] [--no-feeds]

Prepare the NEXAWRT_FLAVOR=official|nss source at its pinned commit, apply the
single-large-UBI RAM-only patches, copy the matching seed config/files, rewrite
all feeds to exact commit pins, and optionally install the feeds.
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

pin_feed() {
  local feed="$1"
  local expected_repo="$2"
  local revision="$3"
  local input="$WORK_DIR/feeds.conf.default"
  local output="$WORK_DIR/feeds.conf.default.tmp"

  awk -v feed="$feed" -v revision="$revision" -v expected_repo="$expected_repo" '
    $1 ~ /^src-git(-full)?$/ && $2 == feed {
      print $1 " " $2 " " expected_repo "^" revision
      found++
      next
    }
    { print }
    END { if (found != 1) exit 42 }
  ' "$input" > "$output" || {
    rm -f "$output"
    echo "Feed $feed is missing or duplicated in feeds.conf.default" >&2
    exit 1
  }
  mv "$output" "$input"
}

expected_feed_names() {
  awk 'NF >= 2 && $1 !~ /^#/ { print $1 }' "$ROOT_DIR/manifests/feeds.lock"
  if [[ "$NEXAWRT_FLAVOR" == nss ]]; then
    printf '%s\n%s\n' "$NSS_PACKAGES_FEED" "$NSS_SQM_FEED"
  fi
}

config_feed_set_matches_locks() {
  local expected expected_unique actual actual_unique

  awk '
    $1 ~ /^src-/ && $1 !~ /^src-git(-full)?$/ { exit 1 }
  ' "$WORK_DIR/feeds.conf.default" || return 1
  expected="$(expected_feed_names | LC_ALL=C sort)"
  expected_unique="$(printf '%s\n' "$expected" | LC_ALL=C sort -u)"
  [[ "$expected" == "$expected_unique" ]] || return 1
  actual="$(awk '$1 ~ /^src-git(-full)?$/ { print $2 }' \
    "$WORK_DIR/feeds.conf.default" | LC_ALL=C sort)"
  actual_unique="$(printf '%s\n' "$actual" | LC_ALL=C sort -u)"
  [[ "$actual" == "$actual_unique" && "$actual" == "$expected" ]]
}

top_level_names() {
  local directory="$1"
  find "$directory" -mindepth 1 -maxdepth 1 -exec basename {} \; | LC_ALL=C sort
}

feed_top_level_matches_locks() {
  local expected actual feed entry

  [[ -d "$WORK_DIR/feeds" ]] || return 1
  expected="$(expected_feed_names | LC_ALL=C sort)"
  actual="$(top_level_names "$WORK_DIR/feeds")"
  [[ "$actual" == "$expected" ]] || return 1
  while IFS= read -r feed; do
    [[ -n "$feed" ]] || continue
    entry="$WORK_DIR/feeds/$feed"
    [[ -d "$entry" && ! -L "$entry" ]] || return 1
  done <<< "$expected"
}

package_feed_links_match_locks() {
  local expected actual feed directory entry feed_root resolved

  [[ -d "$WORK_DIR/package/feeds" ]] || return 1
  expected="$(expected_feed_names | LC_ALL=C sort)"
  actual="$(top_level_names "$WORK_DIR/package/feeds")"
  [[ "$actual" == "$expected" ]] || return 1

  while IFS= read -r feed; do
    [[ -n "$feed" ]] || continue
    directory="$WORK_DIR/package/feeds/$feed"
    [[ -d "$directory" && ! -L "$directory" ]] || return 1
    feed_root="$(cd -P "$WORK_DIR/feeds/$feed" && pwd -P)" || return 1
    while IFS= read -r -d '' entry; do
      [[ -L "$entry" && -d "$entry" ]] || return 1
      resolved="$(cd -P "$entry" 2>/dev/null && pwd -P)" || return 1
      case "$resolved" in
        "$feed_root"/*) ;;
        *) return 1 ;;
      esac
    done < <(find "$directory" -mindepth 1 -maxdepth 1 -print0)
  done <<< "$expected"
}

feed_checkout_is_clean() {
  local feed="$1"
  local checkout="$WORK_DIR/feeds/$feed"
  local git_dir sparse_checkout sparse_index sparse_entries index_tags untracked ignored

  git_dir="$(git -C "$checkout" rev-parse --absolute-git-dir 2>/dev/null)" || return 1
  sparse_checkout="$(git -C "$checkout" config --get core.sparseCheckout 2>/dev/null || true)"
  sparse_index="$(git -C "$checkout" config --get index.sparse 2>/dev/null || true)"
  sparse_entries="$(git -C "$checkout" ls-files --sparse --stage 2>/dev/null)" || return 1
  case "$sparse_checkout" in
    ""|false|no|off|0) ;;
    *) echo "feed checkout $feed uses sparse checkout or a sparse index" >&2; return 1 ;;
  esac
  case "$sparse_index" in
    ""|false|no|off|0) ;;
    *) echo "feed checkout $feed uses sparse checkout or a sparse index" >&2; return 1 ;;
  esac
  if [[ -e "$git_dir/info/sparse-checkout" ]] ||
      grep -Eq '^040000 ' <<<"$sparse_entries"; then
    echo "feed checkout $feed uses sparse checkout or a sparse index" >&2
    return 1
  fi

  index_tags="$(git -C "$checkout" ls-files -v)" || return 1
  if grep -Eq '^[a-z] ' <<<"$index_tags"; then
    echo "feed checkout $feed has assume-unchanged index entries" >&2
    return 1
  fi
  if grep -Eq '^[Ss] ' <<<"$index_tags"; then
    echo "feed checkout $feed has skip-worktree index entries" >&2
    return 1
  fi

  git -C "$checkout" diff-files --quiet --ignore-submodules -- || {
    echo "feed checkout $feed is not clean" >&2
    return 1
  }
  git -C "$checkout" diff-index --quiet --cached HEAD -- || {
    echo "feed checkout $feed is not clean" >&2
    return 1
  }
  untracked="$(git -C "$checkout" ls-files --others --exclude-standard)" || return 1
  if [[ -n "$untracked" ]]; then
    echo "feed checkout $feed is not clean" >&2
    return 1
  fi
  ignored="$(git -C "$checkout" ls-files --others --ignored --exclude-standard)" || return 1
  if [[ -n "$ignored" ]]; then
    echo "feed checkout $feed contains ignored files" >&2
    return 1
  fi
}

feed_checkout_matches_lock() {
  local feed="$1"
  local revision="$2"
  local expected_repo="$3"
  local checkout="$WORK_DIR/feeds/$feed"
  local remote_urls

  [[ -d "$checkout/.git" ]] || return 1
  [[ "$(git -C "$checkout" rev-parse --verify HEAD 2>/dev/null)" == "$revision" ]] || return 1
  remote_urls="$(git -C "$checkout" remote get-url --all origin 2>/dev/null)" || return 1
  [[ "$remote_urls" == "$expected_repo" ]] || return 1
  feed_checkout_is_clean "$feed"
}

feed_checkouts_match_locks() {
  local feed expected_repo revision

  config_feed_set_matches_locks || return 1
  while read -r feed expected_repo revision; do
    [[ -n "$feed" && "${feed:0:1}" != '#' ]] || continue
    feed_checkout_matches_lock "$feed" "$revision" "$expected_repo" || return 1
  done < "$ROOT_DIR/manifests/feeds.lock"

  if [[ "$NEXAWRT_FLAVOR" == nss ]]; then
    feed_checkout_matches_lock \
      "$NSS_PACKAGES_FEED" "$NSS_PACKAGES_COMMIT" "$NSS_PACKAGES_REPO" || return 1
    feed_checkout_matches_lock \
      "$NSS_SQM_FEED" "$NSS_SQM_COMMIT" "$NSS_SQM_REPO" || return 1
  fi
}

remove_generated_feed_metadata() {
  local feed index targetindex temporary

  if [[ -L "$WORK_DIR/feeds/base" && "$(readlink "$WORK_DIR/feeds/base")" == ../package ]]; then
    rm "$WORK_DIR/feeds/base"
  fi
  while IFS= read -r feed; do
    [[ -n "$feed" ]] || continue
    index="$WORK_DIR/feeds/$feed.index"
    targetindex="$WORK_DIR/feeds/$feed.targetindex"
    temporary="$WORK_DIR/feeds/$feed.tmp"
    if [[ -L "$index" && "$(readlink "$index")" == "$feed.tmp/.packageinfo" ]]; then
      rm "$index"
    fi
    if [[ -L "$targetindex" && "$(readlink "$targetindex")" == "$feed.tmp/.targetinfo" ]]; then
      rm "$targetindex"
    fi
    [[ ! -d "$temporary" || -L "$temporary" ]] || rm -rf "$temporary"
  done < <(expected_feed_names)
}

reset_feed_checkouts() {
  rm -rf "$WORK_DIR/feeds" "$WORK_DIR/package/feeds" "$WORK_DIR/.nexawrt-feeds-state"
}

write_feed_state() {
  local state="$1"
  local marker="$WORK_DIR/.nexawrt-feeds-state"
  local temporary="$marker.tmp"

  printf 'version=1\nflavor=%s\nstate=%s\n' "$NEXAWRT_FLAVOR" "$state" > "$temporary"
  mv "$temporary" "$marker"
}

if ((CLEAN)); then
  rm -rf "$WORK_DIR"
fi

if [[ ! -d "$WORK_DIR/.git" ]]; then
  rm -rf "$WORK_DIR"
  mkdir -p "$WORK_DIR"
  git -C "$WORK_DIR" init -q
  git -C "$WORK_DIR" remote add origin "$SOURCE_REPO"
fi

cd "$WORK_DIR"
origin_url="$(git remote get-url origin)"
if [[ "$origin_url" != "$SOURCE_REPO" ]]; then
  echo "Refusing unexpected OpenWrt remote: $origin_url" >&2
  exit 1
fi

fetched=0
for attempt in 1 2 3; do
  if GIT_TERMINAL_PROMPT=0 git -c http.version=HTTP/1.1 fetch --depth 1 origin "$SOURCE_COMMIT"; then
    fetched_commit="$(git rev-parse FETCH_HEAD)"
    if [[ "$fetched_commit" != "$SOURCE_COMMIT" ]]; then
      echo "Fetched commit mismatch: expected $SOURCE_COMMIT, got $fetched_commit" >&2
      exit 1
    fi
    fetched=1
    break
  fi
  echo "$NEXAWRT_FLAVOR source fetch attempt $attempt failed; retrying..." >&2
  sleep $((attempt * 3))
done
((fetched == 1)) || { echo "Unable to fetch pinned $NEXAWRT_FLAVOR source" >&2; exit 1; }

git checkout --detach --force "$SOURCE_COMMIT"
git reset --hard "$SOURCE_COMMIT"
git clean -fd

if [[ "$(git rev-parse HEAD)" != "$SOURCE_COMMIT" ]]; then
  echo "$NEXAWRT_FLAVOR source commit verification failed" >&2
  exit 1
fi

for patch in "$ROOT_DIR"/patches/[0-9][0-9][0-9]-*.patch; do
  git apply --check "$patch"
  git apply "$patch"
done

while read -r feed expected_repo revision; do
  [[ -n "$feed" && "${feed:0:1}" != '#' ]] || continue
  pin_feed "$feed" "$expected_repo" "$revision"
done < "$ROOT_DIR/manifests/feeds.lock"

if [[ "$NEXAWRT_FLAVOR" == nss ]]; then
  pin_feed "$NSS_PACKAGES_FEED" "$NSS_PACKAGES_REPO" "$NSS_PACKAGES_COMMIT"
  pin_feed "$NSS_SQM_FEED" "$NSS_SQM_REPO" "$NSS_SQM_COMMIT"
fi
config_feed_set_matches_locks || {
  echo "Enabled feeds do not exactly match the $NEXAWRT_FLAVOR lock set" >&2
  exit 1
}

rm -rf files
mkdir -p files
rsync -a "$ROOT_DIR/files/" files/
if [[ "$NEXAWRT_FLAVOR" == nss && -d "$ROOT_DIR/files-nss" ]]; then
  rsync -a "$ROOT_DIR/files-nss/" files/
fi
cp "$SEED_CONFIG" .config

# Never reuse an existing feed checkout. Keep only the shared download cache;
# feeds and package/feeds are rebuilt from the exact pins on every preparation.
reset_feed_checkouts
if ((WITH_FEEDS)); then
  feeds_updated=0
  for attempt in 1 2 3; do
    if ./scripts/feeds update -a && feed_checkouts_match_locks; then
      feeds_updated=1
      break
    fi
    echo "Feed update attempt $attempt failed or left a non-exact checkout; retrying cleanly..." >&2
    reset_feed_checkouts
    sleep $((attempt * 3))
  done
  ((feeds_updated == 1)) || { echo "Unable to update pinned feeds" >&2; exit 1; }
  ./scripts/feeds install -a
  # Feed indexing may normalize .config while feed symbols are not yet visible.
  # Restore the locked seed after all packages are installed, then resolve it.
  cp "$SEED_CONFIG" .config
  make defconfig
  # scripts/feeds needs its generated indexes during install, but they are not
  # part of the locked checkout set and must not remain in the prepared tree.
  remove_generated_feed_metadata
  feed_checkouts_match_locks && feed_top_level_matches_locks && \
    package_feed_links_match_locks || {
    echo "Pinned feeds or installed package links changed during installation or defconfig" >&2
    exit 1
  }
  write_feed_state feeds-installed
else
  write_feed_state no-feeds
fi

NEXAWRT_FLAVOR="$NEXAWRT_FLAVOR" OPENWRT_REPO_OVERRIDE="$SOURCE_REPO" \
  "$ROOT_DIR/scripts/validate.sh" --source "$WORK_DIR"
printf 'Prepared %s source %s (%s) at %s\n' \
  "$NEXAWRT_FLAVOR" "$SOURCE_COMMIT" "$SOURCE_LABEL" "$WORK_DIR"
