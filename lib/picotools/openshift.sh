#!/usr/bin/env bash

if [ "${PICOTOOLS_OPENSHIFT_SH_LOADED:-0}" -eq 1 ]; then
  return 0
fi
PICOTOOLS_OPENSHIFT_SH_LOADED=1

if [ "${PICOTOOLS_COMMANDS_SH_LOADED:-0}" -ne 1 ]; then
  # shellcheck source=commands.sh
  # shellcheck disable=SC1091
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/commands.sh"
fi

picotools_require_oc() {
  picotools_require_command oc
}

picotools_oc() {
  local namespace="$1"
  shift

  if [ -n "$namespace" ]; then
    oc -n "$namespace" "$@"
  else
    oc "$@"
  fi
}

picotools_oc_adm_top_pods() {
  local namespace="$1"
  local -a cmd=(oc adm top pods --no-headers)

  if [ -n "$namespace" ]; then
    cmd+=(--namespace "$namespace")
  fi

  "${cmd[@]}"
}
