#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SANITIZER="$ROOT_DIR/scripts/sanitize-git-environment.sh"
fail() { echo "test_git_environment_policy: $*" >&2; exit 1; }

[[ -f "$SANITIZER" && ! -L "$SANITIZER" && -x "$SANITIZER" ]] ||
  fail 'shared Git environment sanitizer is missing, unsafe, or not executable'

entrypoints=(
  prepare.sh
  build.sh
  validate.sh
  collect-build-evidence.sh
  release.sh
  stage-nss-artifact.sh
  compare-reproducible-builds.sh
)
for script in "${entrypoints[@]}"; do
  path="$ROOT_DIR/scripts/$script"
  [[ "$(grep -Fxc 'source "$ROOT_DIR/scripts/sanitize-git-environment.sh"' "$path")" == 1 ]] ||
    fail "$script does not source the sanitizer exactly once"
  [[ "$(grep -Fxc 'nexawrt_sanitize_git_environment' "$path")" == 1 ]] ||
    fail "$script does not invoke the sanitizer exactly once"
done

# Repository selectors, object/index redirections, config injections, helper
# paths, and templates must not survive the sanitizer. Numbered config entries
# deliberately include a high index to ensure removal is not hard-coded to 0.
env \
  GIT_DIR=/tmp/attacker.git \
  GIT_WORK_TREE=/tmp/attacker-tree \
  GIT_INDEX_FILE=/tmp/attacker-index \
  GIT_OBJECT_DIRECTORY=/tmp/attacker-objects \
  GIT_ALTERNATE_OBJECT_DIRECTORIES=/tmp/attacker-alt \
  GIT_COMMON_DIR=/tmp/attacker-common \
  GIT_NAMESPACE=attacker \
  GIT_REPLACE_REF_BASE=refs/evil/ \
  GIT_SHALLOW_FILE=/tmp/attacker-shallow \
  GIT_QUARANTINE_PATH=/tmp/attacker-quarantine \
  GIT_CONFIG=/tmp/attacker-config \
  GIT_CONFIG_PARAMETERS="'core.hooksPath'='/tmp/attacker-hooks'" \
  GIT_CONFIG_GLOBAL=/tmp/attacker-global \
  GIT_CONFIG_SYSTEM=/tmp/attacker-system \
  GIT_CONFIG_COUNT=10 \
  GIT_CONFIG_KEY_0=core.hooksPath \
  GIT_CONFIG_VALUE_0=/tmp/attacker-hooks \
  GIT_CONFIG_KEY_9=url.https://attacker.invalid/.insteadOf \
  GIT_CONFIG_VALUE_9=https://github.com/ \
  GIT_EXEC_PATH=/tmp/attacker-exec \
  GIT_TEMPLATE_DIR=/tmp/attacker-template \
  GIT_ATTR_SOURCE=deadbeef \
  bash -euo pipefail -c '
    source "$1"
    nexawrt_sanitize_git_environment
    forbidden=(
      GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY
      GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE
      GIT_REPLACE_REF_BASE GIT_SHALLOW_FILE GIT_QUARANTINE_PATH
      GIT_CONFIG GIT_CONFIG_PARAMETERS GIT_CONFIG_SYSTEM GIT_CONFIG_COUNT
      GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 GIT_CONFIG_KEY_9 GIT_CONFIG_VALUE_9
      GIT_EXEC_PATH GIT_TEMPLATE_DIR GIT_ATTR_SOURCE
    )
    for variable in "${forbidden[@]}"; do
      [[ -z "${!variable+x}" ]] || exit 91
    done
    [[ "$GIT_CONFIG_NOSYSTEM" == 1 ]]
    [[ "$GIT_CONFIG_GLOBAL" == /dev/null ]]
    [[ "$GIT_NO_REPLACE_OBJECTS" == 1 ]]
    [[ "$GIT_TERMINAL_PROMPT" == 0 ]]
  ' _ "$SANITIZER" || fail 'hostile ambient Git environment survived sanitization'

echo 'ambient Git repository/config/helper redirection is fail-closed: OK'

POLICY="$ROOT_DIR/scripts/git-metadata-policy.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nexawrt-git-metadata-policy.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT
CHECKOUT="$TMP_DIR/checkout"
git -c init.templateDir= init -q "$CHECKOUT"
git -C "$CHECKOUT" remote add origin https://example.invalid/canonical.git
# shellcheck source=../scripts/git-metadata-policy.sh
source "$POLICY"

git -C "$CHECKOUT" config --local remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
nexawrt_git_metadata_is_safe "$CHECKOUT" 'wildcard fixture' >/dev/null ||
  fail 'canonical wildcard origin fetch refspec was rejected'

git -C "$CHECKOUT" config --local remote.origin.fetch '+refs/heads/master:refs/remotes/origin/master'
nexawrt_git_metadata_is_safe "$CHECKOUT" 'single-branch fixture' >/dev/null ||
  fail 'canonical single-branch origin fetch refspec was rejected'

git -C "$CHECKOUT" config --local remote.origin.fetch '+refs/heads/master:refs/remotes/origin/attacker'
if nexawrt_git_metadata_is_safe "$CHECKOUT" 'mismatched branch fixture' >/dev/null 2>&1; then
  fail 'mismatched single-branch origin fetch refspec was accepted'
fi

invalid_branches=(
  'foo/../bar'
  '.hidden'
  'foo.lock'
  'foo//bar'
  'foo/.hidden'
  'foo/bar.'
  'foo/'
)
for branch in "${invalid_branches[@]}"; do
  git -C "$CHECKOUT" config --local remote.origin.fetch \
    "+refs/heads/$branch:refs/remotes/origin/$branch"
  if nexawrt_git_metadata_is_safe "$CHECKOUT" "invalid refname fixture: $branch" >/dev/null 2>&1; then
    fail "invalid single-branch origin fetch refspec was accepted: $branch"
  fi
done

MALICIOUS_BIN="$TMP_DIR/malicious-bin"
MALICIOUS_PYTHONPATH="$TMP_DIR/malicious-pythonpath"
PATH_GIT_MARKER="$TMP_DIR/path-git-used"
SITECUSTOMIZE_MARKER="$TMP_DIR/sitecustomize-loaded"
SYSTEM_PATH="$(builtin command -p getconf PATH)" ||
  fail 'could not determine system default command path for hostile PATH fixture'
SYSTEM_GIT="$(hash -r; PATH="$SYSTEM_PATH" builtin command -p -v git)" ||
  fail 'could not resolve system-default Git for hostile PATH fixture'
[[ "$SYSTEM_GIT" == /* && -f "$SYSTEM_GIT" && -x "$SYSTEM_GIT" ]] ||
  fail 'system-default Git fixture is not an absolute executable file'
mkdir -p "$MALICIOUS_BIN" "$MALICIOUS_PYTHONPATH"
cat >"$MALICIOUS_BIN/git" <<'EOF'
#!/usr/bin/env bash
printf 'invoked\n' >"$NEXAWRT_TEST_PATH_GIT_MARKER"
if [[ "${1-}" == check-ref-format ]]; then
  exit 0
fi
exec "$NEXAWRT_TEST_SYSTEM_GIT" "$@"
EOF
chmod +x "$MALICIOUS_BIN/git"
cat >"$MALICIOUS_PYTHONPATH/sitecustomize.py" <<'PY'
import os
import subprocess

with open(os.environ["NEXAWRT_TEST_SITECUSTOMIZE_MARKER"], "w", encoding="utf-8") as marker:
    marker.write("loaded\n")

real_run = subprocess.run


def malicious_run(args, *pargs, **kwargs):
    if isinstance(args, (list, tuple)) and "check-ref-format" in args:
        return subprocess.CompletedProcess(args, 0)
    return real_run(args, *pargs, **kwargs)


subprocess.run = malicious_run
PY

git -C "$CHECKOUT" config --local remote.origin.fetch \
  '+refs/heads/foo.lock:refs/remotes/origin/foo.lock'
if (
  export PATH="$MALICIOUS_BIN:$PATH"
  export PYTHONPATH="$MALICIOUS_PYTHONPATH"
  export NEXAWRT_TEST_PATH_GIT_MARKER="$PATH_GIT_MARKER"
  export NEXAWRT_TEST_SITECUSTOMIZE_MARKER="$SITECUSTOMIZE_MARKER"
  export NEXAWRT_TEST_SYSTEM_GIT="$SYSTEM_GIT"
  nexawrt_git_metadata_is_safe "$CHECKOUT" 'hostile command resolution fixture' \
    >/dev/null 2>&1
); then
  fail 'invalid foo.lock refspec was accepted under hostile PATH/PYTHONPATH'
fi
[[ ! -e "$PATH_GIT_MARKER" ]] ||
  fail 'Git metadata policy executed the hostile PATH git wrapper'
[[ ! -e "$SITECUSTOMIZE_MARKER" ]] ||
  fail 'Git metadata policy loaded PYTHONPATH sitecustomize code'

echo 'canonical wildcard/single-branch fetch refspec policy is fail-closed: OK'
