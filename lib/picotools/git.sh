#!/usr/bin/env bash

if [ "${PICOTOOLS_GIT_SH_LOADED:-0}" -eq 1 ]; then
  return 0
fi
PICOTOOLS_GIT_SH_LOADED=1

if [ "${PICOTOOLS_COMMANDS_SH_LOADED:-0}" -ne 1 ]; then
  # shellcheck source=commands.sh
  # shellcheck disable=SC1091
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/commands.sh"
fi

picotools_require_git_repo() {
  picotools_require_command git

  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo 'Error: current directory is not a git repository' >&2
    exit 1
  fi
}

picotools_git_default_branch() {
  local remote="$1"
  local default_ref
  local default_branch
  local line

  git remote set-head "$remote" --auto >/dev/null 2>&1 || true

  default_ref=$(git symbolic-ref --quiet --short "refs/remotes/${remote}/HEAD" 2>/dev/null || true)
  if [ -n "$default_ref" ]; then
    printf '%s\n' "${default_ref#"${remote}/"}"
    return 0
  fi

  while IFS= read -r line; do
    case "$line" in
    *'HEAD branch:'*)
      default_branch=${line##*: }
      if [ -n "$default_branch" ] && [ "$default_branch" != '(not queried)' ]; then
        printf '%s\n' "$default_branch"
        return 0
      fi
      ;;
    esac
  done < <(git remote show -n "$remote" 2>/dev/null || true)

  if git rev-parse --verify --quiet "refs/remotes/${remote}/main" >/dev/null; then
    echo 'main'
    return 0
  fi

  echo ''
}
