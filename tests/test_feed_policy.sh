#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nexawrt-feed-policy.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

expect_failure() {
  local description="$1"
  local expected="$2"
  shift 2
  local output="$TMP_DIR/failure-output"

  if "$@" >"$output" 2>&1; then
    echo "$description unexpectedly passed" >&2
    exit 1
  fi
  grep -Fq "$expected" "$output" || {
    echo "$description failed for an unexpected reason" >&2
    cat "$output" >&2
    exit 1
  }
}

POLICY_REPO="$TMP_DIR/repo"
mkdir -p "$POLICY_REPO"
rsync -a --exclude='.git' --exclude='.work' --exclude='dist' --exclude='dist-nss' \
  --exclude='build.log' --exclude='build-nss.log' "$ROOT_DIR/" "$POLICY_REPO/"

# Official selected-flavor validation must not parse or require the experimental
# NSS lock. Repository-wide CI can still invoke the NSS flavor separately.
mv "$POLICY_REPO/manifests/nss.lock" "$TMP_DIR/nss.lock.good"
NEXAWRT_FLAVOR=official "$POLICY_REPO/scripts/validate.sh" >/dev/null
NEXAWRT_FLAVOR=official "$POLICY_REPO/scripts/prepare.sh" --help >/dev/null
printf 'this is deliberately not valid shell (\n' > "$POLICY_REPO/manifests/nss.lock"
NEXAWRT_FLAVOR=official "$POLICY_REPO/scripts/validate.sh" >/dev/null
NEXAWRT_FLAVOR=official "$POLICY_REPO/scripts/prepare.sh" --help >/dev/null
expect_failure "NSS validation with malformed NSS lock" "syntax error" \
  env NEXAWRT_FLAVOR=nss "$POLICY_REPO/scripts/validate.sh"
mv "$TMP_DIR/nss.lock.good" "$POLICY_REPO/manifests/nss.lock"

cp -p "$POLICY_REPO/manifests/nss.lock" "$TMP_DIR/nss.lock.clean"
printf '# %s=%s_%s\n' 'token' 'ghp' '01234567890123456789' >> \
  "$POLICY_REPO/manifests/nss.lock"
NEXAWRT_FLAVOR=official "$POLICY_REPO/scripts/validate.sh" >/dev/null
expect_failure "NSS credential scan includes NSS lock" "possible embedded credential detected" \
  env NEXAWRT_FLAVOR=nss "$POLICY_REPO/scripts/validate.sh"
mv "$TMP_DIR/nss.lock.clean" "$POLICY_REPO/manifests/nss.lock"
echo 'selected-flavor lock isolation: OK'

# Official validation must not parse NSS-only helpers or policy tests. NSS
# validation still owns their syntax checks and must fail closed for each one.
for nss_only_file in \
  scripts/nss-diagnostics.sh \
  scripts/stage-nss-artifact.sh \
  tests/test_feed_policy.sh \
  tests/test_nss_artifact_policy.sh; do
  candidate="$POLICY_REPO/$nss_only_file"
  backup="$TMP_DIR/$(basename "$nss_only_file").good"
  cp -p "$candidate" "$backup"
  printf '#!/usr/bin/env bash\nif then\n' > "$candidate"
  chmod +x "$candidate"
  NEXAWRT_FLAVOR=official "$POLICY_REPO/scripts/validate.sh" >/dev/null
  expect_failure "NSS-only syntax under NSS validation: $nss_only_file" "syntax error" \
    env NEXAWRT_FLAVOR=nss "$POLICY_REPO/scripts/validate.sh"
  mv "$backup" "$candidate"
done
echo 'selected-flavor script syntax isolation: OK'

# Official credential scanning must not read NSS-only helpers or policy tests.
# Build the sentinel in pieces so this test source does not contain a pattern.
for nss_only_file in \
  scripts/nss-diagnostics.sh \
  scripts/stage-nss-artifact.sh \
  tests/test_feed_policy.sh \
  tests/test_nss_artifact_policy.sh; do
  candidate="$POLICY_REPO/$nss_only_file"
  backup="$TMP_DIR/$(basename "$nss_only_file").credential.good"
  cp -p "$candidate" "$backup"
  printf '\n# %s=%s_%s\n' 'token' 'ghp' '01234567890123456789' >> "$candidate"
  NEXAWRT_FLAVOR=official "$POLICY_REPO/scripts/validate.sh" >/dev/null
  expect_failure "NSS-only credential under NSS validation: $nss_only_file" \
    "possible embedded credential detected" \
    env NEXAWRT_FLAVOR=nss "$POLICY_REPO/scripts/validate.sh"
  mv "$backup" "$candidate"
done
echo 'selected-flavor credential scan isolation: OK'

SOURCE="$TMP_DIR/source"
mkdir -p "$SOURCE/feeds" "$SOURCE/package/feeds" "$TMP_DIR/origins"
: > "$SOURCE/feeds.conf.default"
: > "$POLICY_REPO/manifests/feeds.lock"

first_feed=""
while read -r feed; do
  [[ -n "$feed" ]] || continue
  checkout="$SOURCE/feeds/$feed"
  mkdir -p "$checkout"
  git -c init.templateDir= -C "$checkout" init -q
  git -C "$checkout" config user.name 'NexaWrt feed policy test'
  git -C "$checkout" config user.email 'nexawrt-feed-policy@example.invalid'
  printf '%s\n' "$feed" > "$checkout/tracked.txt"
  printf 'ignored-fixture.tmp\n' > "$checkout/.gitignore"
  mkdir -p "$checkout/package-$feed"
  printf '# fixture package for %s\n' "$feed" > "$checkout/package-$feed/Makefile"
  git -C "$checkout" add .
  git -C "$checkout" commit -qm "fixture: $feed"
  revision="$(git -C "$checkout" rev-parse HEAD)"
  origin="file://$TMP_DIR/origins/$feed.git"
  git -C "$checkout" remote add origin "$origin"
  printf '%s %s %s\n' "$feed" "$origin" "$revision" >> "$POLICY_REPO/manifests/feeds.lock"
  printf 'src-git %s %s^%s\n' "$feed" "$origin" "$revision" >> "$SOURCE/feeds.conf.default"
  mkdir -p "$SOURCE/package/feeds/$feed"
  ln -s "../../../feeds/$feed/package-$feed" \
    "$SOURCE/package/feeds/$feed/package-$feed"
  [[ -n "$first_feed" ]] || first_feed="$feed"
done <<'FEEDS'
packages
luci
routing
telephony
video
FEEDS

printf 'version=1\nflavor=official\nstate=feeds-installed\n' > "$SOURCE/.nexawrt-feeds-state"
NEXAWRT_FLAVOR=official "$POLICY_REPO/scripts/validate.sh" \
  --source "$SOURCE" --feed-policy-only >/dev/null

mv "$SOURCE/.nexawrt-feeds-state" "$TMP_DIR/feed-state-marker"
expect_failure "source without feed state marker" "feed state marker is missing" \
  env NEXAWRT_FLAVOR=official "$POLICY_REPO/scripts/validate.sh" \
  --source "$SOURCE" --feed-policy-only
mv "$TMP_DIR/feed-state-marker" "$SOURCE/.nexawrt-feeds-state"

printf 'modified\n' >> "$SOURCE/feeds/$first_feed/tracked.txt"
expect_failure "tracked feed modification" "feed checkout $first_feed is not clean" \
  env NEXAWRT_FLAVOR=official "$POLICY_REPO/scripts/validate.sh" \
  --source "$SOURCE" --feed-policy-only
git -C "$SOURCE/feeds/$first_feed" reset --hard -q HEAD

printf 'staged\n' >> "$SOURCE/feeds/$first_feed/tracked.txt"
git -C "$SOURCE/feeds/$first_feed" add tracked.txt
expect_failure "staged feed modification" "feed checkout $first_feed is not clean" \
  env NEXAWRT_FLAVOR=official "$POLICY_REPO/scripts/validate.sh" \
  --source "$SOURCE" --feed-policy-only
git -C "$SOURCE/feeds/$first_feed" reset --hard -q HEAD

git -C "$SOURCE/feeds/$first_feed" update-index --assume-unchanged tracked.txt
printf 'hidden by assume-unchanged\n' >> "$SOURCE/feeds/$first_feed/tracked.txt"
expect_failure "assume-unchanged feed modification" \
  "feed checkout $first_feed has assume-unchanged index entries" \
  env NEXAWRT_FLAVOR=official "$POLICY_REPO/scripts/validate.sh" \
  --source "$SOURCE" --feed-policy-only
git -C "$SOURCE/feeds/$first_feed" update-index --no-assume-unchanged tracked.txt
git -C "$SOURCE/feeds/$first_feed" reset --hard -q HEAD

git -C "$SOURCE/feeds/$first_feed" update-index --skip-worktree tracked.txt
printf 'hidden by skip-worktree\n' >> "$SOURCE/feeds/$first_feed/tracked.txt"
expect_failure "skip-worktree feed modification" \
  "feed checkout $first_feed has skip-worktree index entries" \
  env NEXAWRT_FLAVOR=official "$POLICY_REPO/scripts/validate.sh" \
  --source "$SOURCE" --feed-policy-only
git -C "$SOURCE/feeds/$first_feed" update-index --no-skip-worktree tracked.txt
git -C "$SOURCE/feeds/$first_feed" reset --hard -q HEAD

git -C "$SOURCE/feeds/$first_feed" config core.sparseCheckout true
expect_failure "sparse checkout feed state" \
  "feed checkout $first_feed uses sparse checkout or a sparse index" \
  env NEXAWRT_FLAVOR=official "$POLICY_REPO/scripts/validate.sh" \
  --source "$SOURCE" --feed-policy-only
git -C "$SOURCE/feeds/$first_feed" config --unset core.sparseCheckout

git -C "$SOURCE/feeds/$first_feed" config index.sparse true
expect_failure "sparse index feed state" \
  "feed checkout $first_feed uses sparse checkout or a sparse index" \
  env NEXAWRT_FLAVOR=official "$POLICY_REPO/scripts/validate.sh" \
  --source "$SOURCE" --feed-policy-only
git -C "$SOURCE/feeds/$first_feed" config --unset index.sparse

printf 'untracked\n' > "$SOURCE/feeds/$first_feed/untracked-package.mk"
expect_failure "untracked feed package" "feed checkout $first_feed is not clean" \
  env NEXAWRT_FLAVOR=official "$POLICY_REPO/scripts/validate.sh" \
  --source "$SOURCE" --feed-policy-only
rm -f "$SOURCE/feeds/$first_feed/untracked-package.mk"

touch "$SOURCE/feeds/$first_feed/ignored-fixture.tmp"
expect_failure "ignored feed file" "feed checkout $first_feed contains ignored files" \
  env NEXAWRT_FLAVOR=official "$POLICY_REPO/scripts/validate.sh" \
  --source "$SOURCE" --feed-policy-only
rm -f "$SOURCE/feeds/$first_feed/ignored-fixture.tmp"

expected_origin="$(git -C "$SOURCE/feeds/$first_feed" remote get-url origin)"
git -C "$SOURCE/feeds/$first_feed" remote set-url origin 'file:///unexpected-feed-origin.git'
expect_failure "feed origin mismatch" "feed checkout $first_feed uses an unexpected origin" \
  env NEXAWRT_FLAVOR=official "$POLICY_REPO/scripts/validate.sh" \
  --source "$SOURCE" --feed-policy-only
git -C "$SOURCE/feeds/$first_feed" remote set-url origin "$expected_origin"

cp "$SOURCE/feeds.conf.default" "$TMP_DIR/feeds.conf.default.good"
tampered_origin='file:///coordinated-tampered-origin.git'
first_revision="$(git -C "$SOURCE/feeds/$first_feed" rev-parse HEAD)"
awk -v feed="$first_feed" -v origin="$tampered_origin" -v revision="$first_revision" '
  $1 ~ /^src-git(-full)?$/ && $2 == feed { $3 = origin "^" revision }
  { print }
' "$TMP_DIR/feeds.conf.default.good" > "$SOURCE/feeds.conf.default"
git -C "$SOURCE/feeds/$first_feed" remote set-url origin "$tampered_origin"
expect_failure "coordinated feed URL and origin tampering" \
  "feed $first_feed is not uniquely pinned to $first_revision at the expected repository" \
  env NEXAWRT_FLAVOR=official "$POLICY_REPO/scripts/validate.sh" \
  --source "$SOURCE" --feed-policy-only
cp "$TMP_DIR/feeds.conf.default.good" "$SOURCE/feeds.conf.default"
git -C "$SOURCE/feeds/$first_feed" remote set-url origin "$expected_origin"

printf 'src-git evil file:///evil-feed.git^%040d\n' 0 >> "$SOURCE/feeds.conf.default"
expect_failure "extra enabled feed" "enabled feed set does not exactly match" \
  env NEXAWRT_FLAVOR=official "$POLICY_REPO/scripts/validate.sh" \
  --source "$SOURCE" --feed-policy-only
cp "$TMP_DIR/feeds.conf.default.good" "$SOURCE/feeds.conf.default"

cat "$SOURCE/feeds.conf.default" >> "$TMP_DIR/feeds.conf.default.duplicate"
head -n 1 "$SOURCE/feeds.conf.default" >> "$TMP_DIR/feeds.conf.default.duplicate"
cp "$TMP_DIR/feeds.conf.default.duplicate" "$SOURCE/feeds.conf.default"
expect_failure "duplicate enabled feed" "contains duplicate enabled feeds" \
  env NEXAWRT_FLAVOR=official "$POLICY_REPO/scripts/validate.sh" \
  --source "$SOURCE" --feed-policy-only
cp "$TMP_DIR/feeds.conf.default.good" "$SOURCE/feeds.conf.default"

mkdir "$SOURCE/feeds/evil"
expect_failure "extra feeds checkout" "feeds top-level set does not exactly match" \
  env NEXAWRT_FLAVOR=official "$POLICY_REPO/scripts/validate.sh" \
  --source "$SOURCE" --feed-policy-only
rmdir "$SOURCE/feeds/evil"

mkdir "$SOURCE/package/feeds/evil"
expect_failure "extra installed feed" "package/feeds top-level set does not exactly match" \
  env NEXAWRT_FLAVOR=official "$POLICY_REPO/scripts/validate.sh" \
  --source "$SOURCE" --feed-policy-only
rmdir "$SOURCE/package/feeds/evil"

mkdir "$TMP_DIR/external-package"
ln -s "$TMP_DIR/external-package" "$SOURCE/package/feeds/$first_feed/external-package"
expect_failure "external package feed symlink" "symlink resolves outside its feed checkout" \
  env NEXAWRT_FLAVOR=official "$POLICY_REPO/scripts/validate.sh" \
  --source "$SOURCE" --feed-policy-only
rm "$SOURCE/package/feeds/$first_feed/external-package"

printf 'not a symlink\n' > "$SOURCE/package/feeds/$first_feed/regular-file"
expect_failure "regular package feed entry" "contains a non-symlink entry" \
  env NEXAWRT_FLAVOR=official "$POLICY_REPO/scripts/validate.sh" \
  --source "$SOURCE" --feed-policy-only
rm "$SOURCE/package/feeds/$first_feed/regular-file"

mkdir -p "$TMP_DIR/feed-git-metadata"
for checkout in "$SOURCE"/feeds/*; do
  feed="$(basename "$checkout")"
  mv "$checkout/.git" "$TMP_DIR/feed-git-metadata/$feed"
done
expect_failure "feeds directory without Git metadata" "feed checkout missing Git metadata: $first_feed" \
  env NEXAWRT_FLAVOR=official "$POLICY_REPO/scripts/validate.sh" \
  --source "$SOURCE" --feed-policy-only
for checkout in "$SOURCE"/feeds/*; do
  feed="$(basename "$checkout")"
  mv "$TMP_DIR/feed-git-metadata/$feed" "$checkout/.git"
done

printf 'version=1\nflavor=official\nstate=no-feeds\n' > "$SOURCE/.nexawrt-feeds-state"
expect_failure "no-feeds marker with checkout content" "no-feeds source unexpectedly contains feed checkout data" \
  env NEXAWRT_FLAVOR=official "$POLICY_REPO/scripts/validate.sh" \
  --source "$SOURCE" --feed-policy-only
printf 'version=1\nflavor=official\nstate=feeds-installed\n' > "$SOURCE/.nexawrt-feeds-state"

NEXAWRT_FLAVOR=official "$POLICY_REPO/scripts/validate.sh" \
  --source "$SOURCE" --feed-policy-only >/dev/null

echo 'exact feed checkout policy negatives: OK'

NSS_CONFIG="$POLICY_REPO/configs/ax9000-single-ubi-nss.config"
printf 'CONFIG_NSS_FIRMWARE_VERSION_13_0=y\n' >> "$NSS_CONFIG"
expect_failure "unknown NSS firmware version" "must select only NSS firmware version 12.5" \
  env NEXAWRT_FLAVOR=nss "$POLICY_REPO/scripts/validate.sh"
cp "$ROOT_DIR/configs/ax9000-single-ubi-nss.config" "$NSS_CONFIG"
printf 'CONFIG_ATH11K_NSS_FUTURE_ACCEL=y\n' >> "$NSS_CONFIG"
expect_failure "unknown ATH11K NSS symbol" "enabled an ATH11K NSS feature" \
  env NEXAWRT_FLAVOR=nss "$POLICY_REPO/scripts/validate.sh"

echo 'NSS config allowlist negatives: OK'
echo 'feed policy tests: OK'
