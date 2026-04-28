#!/usr/bin/env bash

if [ "${PICOTOOLS_VERSION_SH_LOADED:-0}" -eq 1 ]; then
  return 0
fi
PICOTOOLS_VERSION_SH_LOADED=1

picotools_resolve_version_file() {
  local script_dir="$1"
  local candidate

  for candidate in "$script_dir/../VERSION" "$script_dir/../../VERSION"; do
    if [ -f "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  return 1
}

picotools_print_version() {
  local script_dir="$1"
  local version_file

  if version_file=$(picotools_resolve_version_file "$script_dir"); then
    tr -d '[:space:]' <"$version_file"
    printf '\n'
  else
    echo "unknown"
  fi
}
