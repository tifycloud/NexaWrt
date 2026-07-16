#!/usr/bin/env bash
# Shared fail-closed Git process environment for all build and verification entrypoints.
# This file is sourced; do not enable shell options or execute repository operations here.

nexawrt_sanitize_git_environment() {
  local variable

  # Prevent callers from redirecting Git to unrelated metadata, object stores,
  # indexes, worktrees, namespaces, config files, executable helpers, or
  # templates. Repository-local .git/config remains available and is verified
  # separately by the calling policy.
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
    GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE \
    GIT_REPLACE_REF_BASE GIT_SHALLOW_FILE GIT_QUARANTINE_PATH \
    GIT_CONFIG GIT_CONFIG_PARAMETERS GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM \
    GIT_EXEC_PATH GIT_TEMPLATE_DIR GIT_ATTR_SOURCE

  # GIT_CONFIG_COUNT plus numbered key/value variables can inject arbitrary
  # config without appearing in any on-disk config file. Remove every numbered
  # entry rather than assuming an attacker used only index zero.
  while IFS='=' read -r variable _; do
    case "$variable" in
      GIT_CONFIG_COUNT|GIT_CONFIG_KEY_[0-9]*|GIT_CONFIG_VALUE_[0-9]*)
        unset "$variable"
        ;;
    esac
  done < <(env)

  export GIT_CONFIG_NOSYSTEM=1
  export GIT_CONFIG_GLOBAL=/dev/null
  export GIT_NO_REPLACE_OBJECTS=1
  export GIT_TERMINAL_PROMPT=0
}
