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
