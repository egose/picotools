#!/usr/bin/env bash

if [ "${PICOTOOLS_K8S_PROFILE_ACTIONS_SH_LOADED:-0}" -eq 1 ]; then
  return 0
fi
PICOTOOLS_K8S_PROFILE_ACTIONS_SH_LOADED=1

k8s_profile_create() {
  local name server namespace namespace_default token_file index target overwrite
  k8s_profile_init || return 1
  # Take the complete physical/visible snapshot BEFORE any interactive input.
  k8s_profile_snapshot_chain || return 1
  k8s_profile_validate_ownership || return 1
  picotools_ui_section 'Create Kubernetes Profile'
  picotools_ui_step 1 3 'Choose profile identity'
  k8s_profile_capture_prompt name k8s_profile_prompt_required Name || return 1
  k8s_profile_validate_name "$name" || return 1
  k8s_profile_find_profile_index "$name" index || return 1
  k8s_profile_target_index "$name" target || return 1
  k8s_profile_preflight_write "${K8S_PROFILE_CHAIN_PATHS[$target]}" || return 1
  if [ "$index" -gt 0 ]; then
    if ! k8s_profile_capture_prompt overwrite k8s_profile_prompt_confirmation "Profile '$name' already exists. Overwrite?"; then
      picotools_cancel
      return 1
    fi
    if [ "$overwrite" != yes ]; then
      picotools_cancel
      return 1
    fi
  fi
  picotools_ui_step 2 3 'Configure API server and Token'
  k8s_profile_capture_prompt server k8s_profile_prompt_required Server || return 1
  k8s_profile_validate_server "$server" || return 1
  k8s_profile_prompt_token_file token_file || return 1
  # Enter accepts the default explicitly so profiles never silently resolve
  # to the cluster default namespace behind the user's back. An overwrite
  # defaults to the profile's existing valid namespace so a blank answer
  # cannot clear what the user (or the cluster admin) already set.
  namespace_default='default'
  if [ "$index" -gt 0 ]; then
    k8s_profile_update_namespace_default "$name" namespace_default || return 1
    [ -n "$namespace_default" ] || namespace_default='default'
  fi
  k8s_profile_capture_prompt namespace k8s_profile_prompt_required Namespace "$namespace_default" || return 1
  k8s_profile_validate_namespace "$namespace" || return 1
  # This also rejects incompatible authentication without replacing its user.
  k8s_profile_plan_change "$name" "$server" true true "$namespace" true || return 1
  picotools_ui_step 3 3 'Review and save profile'
  picotools_ui_summary 'Review Kubernetes Profile' \
    "Profile: $name" "Server: $server" "Namespace: $namespace" 'Token: configured' 'Current context: unchanged'
  debug_log 'Staging a complete profile registration'
  k8s_profile_stage_change "$token_file" || return 1
  k8s_profile_tx_commit k8s_profile_verify_change || return 1
  picotools_ui_summary 'Kubernetes Profile Saved' \
    "Profile: $name" "Server: $server" "Namespace: $namespace" 'Token: configured' 'Current context: unchanged'
  printf "Saved profile '%s'.\n" "$name"
}

k8s_profile_list() {
  k8s_profile_init || return 1
  k8s_profile_read_visible || return 1
  k8s_profile_print_profiles
}
