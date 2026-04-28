#!/usr/bin/env bash

if [ "${PICOTOOLS_GITHUB_SH_LOADED:-0}" -eq 1 ]; then
  return 0
fi
PICOTOOLS_GITHUB_SH_LOADED=1

picotools_resolve_github_coordinates() {
  local script_dir="$1"
  local plugin_path
  local remote_url
  local repo

  plugin_path="${ASDF_PLUGIN_PATH:-$(cd "$script_dir/.." && pwd)}"
  remote_url=$(git -C "$plugin_path" config --get remote.origin.url 2>/dev/null || true)

  case "$remote_url" in
  git@github.com:*.git)
    repo="${remote_url#git@github.com:}"
    repo="${repo%.git}"
    ;;
  ssh://git@github.com/*)
    repo="${remote_url#ssh://git@github.com/}"
    repo="${repo%.git}"
    ;;
  https://github.com/*.git)
    repo="${remote_url#https://github.com/}"
    repo="${repo%.git}"
    ;;
  https://github.com/*)
    repo="${remote_url#https://github.com/}"
    ;;
  *)
    echo "Unable to determine GitHub repository from plugin remote: ${remote_url:-<missing>}" >&2
    echo 'Set ASDF_PICOTOOLS_GITHUB_REPOSITORY=owner/repo to override.' >&2
    exit 1
    ;;
  esac

  printf '%s\n' "$repo"
}
