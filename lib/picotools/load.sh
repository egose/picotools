#!/usr/bin/env bash

if [ "${PICOTOOLS_LOAD_SH_LOADED:-0}" -eq 1 ]; then
  return 0
fi
PICOTOOLS_LOAD_SH_LOADED=1

picotools_lib_dir_from_script_dir() {
  local script_dir="$1"
  local candidate

  for candidate in "$script_dir/../lib/picotools" "$script_dir/../../lib/picotools"; do
    if [ -d "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  return 1
}

picotools_source_modules() {
  local script_dir="$1"
  shift
  local lib_dir
  local module

  lib_dir=$(picotools_lib_dir_from_script_dir "$script_dir") || {
    echo "Error: unable to locate picotools helper modules" >&2
    exit 1
  }

  for module in "$@"; do
    if [ ! -f "$lib_dir/${module}.sh" ]; then
      echo "Error: missing helper module '${module}.sh'" >&2
      exit 1
    fi

    # shellcheck disable=SC1090
    . "$lib_dir/${module}.sh"
  done
}
