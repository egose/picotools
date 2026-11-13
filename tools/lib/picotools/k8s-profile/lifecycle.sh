#!/usr/bin/env bash
# shellcheck disable=SC2016 # Static jq programs own their variables.

if [ "${PICOTOOLS_K8S_PROFILE_LIFECYCLE_SH_LOADED:-0}" -eq 1 ]; then
  return 0
fi
PICOTOOLS_K8S_PROFILE_LIFECYCLE_SH_LOADED=1

k8s_profile_display_name() {
  local index="$1" result_var="$2"
  k8s_profile_json_value "$result_var" --argjson index "$index" "$K8S_PROFILE_DISPLAY_JQ"'
    (.profiles[$index - 1].name | display_text), "\u0000"
  ' "$K8S_PROFILE_TMP_DIR/profiles.json"
}

k8s_profile_display_server() {
  local index="$1" result_var="$2"
  k8s_profile_json_value "$result_var" --argjson index "$index" "$K8S_PROFILE_DISPLAY_JQ"'
    (.profiles[$index - 1].server | if . == "" then "-" else display_text end), "\u0000"
  ' "$K8S_PROFILE_TMP_DIR/profiles.json"
}

# Never pass an existing Server to jq --arg, a prompt, or an external command
# before validating it privately. In particular, a redacted display projection
# is NOT an editable default or a replacement target. Unchanged expected state
# remains in the private inventory and is read there by plan_change.
k8s_profile_update_server_default() {
  set +x
  set +a
  local profile="$1" result_var="$2" k8s_profile_private_server=''
  export -n k8s_profile_private_server
  k8s_profile_json_value k8s_profile_private_server --arg profile "$profile" "$K8S_PROFILE_MODEL_JQ"'
    . as $files | definitions($files; "context"; $profile)[0].data as $context |
    ((definitions($files; "cluster"; ($context.cluster // ""))[0].data.server // "") |
      if contains("\u0000") then "" else . end), "\u0000"
  ' "$K8S_PROFILE_TMP_DIR/inventory.json" || return 1
  if k8s_profile_validate_server "$k8s_profile_private_server" 2>"$K8S_PROFILE_TMP_DIR/diagnostics"; then
    printf -v "$result_var" '%s' "$k8s_profile_private_server"
  else
    printf -v "$result_var" '%s' ''
  fi
  unset k8s_profile_private_server
}

k8s_profile_update_token_status() {
  local profile="$1" result_var="$2"
  k8s_profile_json_value "$result_var" --arg profile "$profile" "$K8S_PROFILE_MODEL_JQ"'
    . as $files | definitions($files; "context"; $profile)[0].data as $context |
    (definitions($files; "user"; ($context.user // ""))[0].data // {}) as $user |
    (if (($user.token // "") | length) > 0 or (($user.tokenFile // "") | length) > 0
     then "configured" else "not configured" end), "\u0000"
  ' "$K8S_PROFILE_TMP_DIR/inventory.json"
}

k8s_profile_check_token_compatibility() {
  local profile="$1" incompatible
  k8s_profile_json_value incompatible --arg profile "$profile" "$K8S_PROFILE_MODEL_JQ"'
    . as $files | definitions($files; "context"; $profile)[0].data as $context |
    ((definitions($files; "user"; ($context.user // ""))[0].data // {}) |
      incompatible_bearer_auth | tostring), "\u0000"
  ' "$K8S_PROFILE_TMP_DIR/inventory.json" || return 1
  if [ "$incompatible" = true ]; then
    k8s_profile_error 'Token replacement is incompatible with exec, auth-provider, basic, or client-certificate/key authentication; keep Token for a Server-only update, or manage authentication separately with kubectl'
    return 1
  fi
}

k8s_profile_token_would_change() {
  local profile="$1" token_file="$2" result_var="$3"
  k8s_profile_json_value "$result_var" --arg profile "$profile" --rawfile token "$token_file" "$K8S_PROFILE_MODEL_JQ"'
    . as $files | definitions($files; "context"; $profile)[0].data as $context |
    (definitions($files; "user"; ($context.user // ""))[0].data // {}) as $user |
    ($user.token != $token or $user.tokenFile != null | tostring), "\u0000"
  ' "$K8S_PROFILE_TMP_DIR/inventory.json"
}

k8s_profile_prompt_update_field() {
  local server_display="$1" token_status="$2"
  k8s_profile_prompt_select_index 'Update fields' 'Select field' 3 false \
    "Server [$server_display]" "Token [$token_status]" Done
}

k8s_profile_prompt_token_action() {
  local status="$1" action=Add
  if [ "$status" = configured ]; then
    action=Replace
  fi
  k8s_profile_prompt_select_index Token 'Select Token action' 1 false \
    "Keep Token [$status]" "$action Token"
}

k8s_profile_update() {
  local index name display_name server_display original_default server_default server=''
  local selected_field token_status token_action token_file='' server_change=false token_change=false
  k8s_profile_init || return 1
  k8s_profile_snapshot_chain || return 1
  k8s_profile_validate_ownership || return 1
  k8s_profile_capture_prompt index k8s_profile_select_index || return 1
  k8s_profile_profile_name "$index" name || return 1
  k8s_profile_recheck_chain || return 1
  k8s_profile_display_name "$index" display_name || return 1
  k8s_profile_display_server "$index" server_display || return 1
  k8s_profile_update_server_default "$name" original_default || return 1
  server_default="$original_default"
  k8s_profile_update_token_status "$name" token_status || return 1
  picotools_ui_section 'Update Kubernetes Profile'
  picotools_ui_step 1 2 'Select fields to update'
  debug_log 'Editing the selected profile; configuration remains unchanged until Done'
  while true; do
    if ! k8s_profile_capture_prompt selected_field k8s_profile_prompt_update_field "$server_display" "$token_status"; then
      picotools_cancel
      return 1
    fi
    case "$selected_field" in
    1)
      k8s_profile_capture_prompt server k8s_profile_prompt_required Server "$server_default" || return 1
      k8s_profile_validate_server "$server" || return 1
      server_default="$server"
      server_display="$server"
      if [ "$server" = "$original_default" ]; then
        server_change=false
        server=''
      else
        server_change=true
      fi
      ;;
    2)
      if ! k8s_profile_capture_prompt token_action k8s_profile_prompt_token_action "$token_status"; then
        picotools_cancel
        return 1
      fi
      if [ "$token_action" = 2 ]; then
        k8s_profile_check_token_compatibility "$name" || return 1
        k8s_profile_prompt_token_file token_file || return 1
        k8s_profile_token_would_change "$name" "$token_file" token_change || return 1
        token_status=configured
      fi
      ;;
    3) break ;;
    esac
  done
  k8s_profile_recheck_chain || return 1
  if [ "$server_change" = false ] && [ "$token_change" = false ]; then
    printf "No changes to profile '%s'.\n" "$display_name"
    return 0
  fi
  # Empty Server means KEEP, not a projected/default/redacted substitute.
  k8s_profile_plan_change "$name" "$server" "$server_change" "$token_change" || return 1
  picotools_ui_summary 'Review Updated Profile' \
    "Profile: $display_name" "Server: $server_display" "Token: $token_status" 'Current context: unchanged'
  picotools_ui_step 2 2 'Save updated settings'
  if [ "$token_change" = false ]; then
    token_file=''
  fi
  k8s_profile_stage_change "$token_file" || return 1
  k8s_profile_tx_commit k8s_profile_verify_change || return 1
  picotools_ui_summary 'Kubernetes Profile Updated' \
    "Profile: $display_name" "Server: $server_display" "Token: $token_status" 'Current context: unchanged'
  printf "Updated profile '%s'.\n" "$display_name"
}

# This describes edits to per-file raw snapshots, not a parallel writer. The
# same expression is used to stage and privately verify all transaction members.
K8S_PROFILE_DELETE_JQ='
  def delete_resources($p; $index):
    [$p.cleanup[] | select($index == null or .index == $index)] as $cleanup |
    .clusters = [(.clusters // [])[] | . as $entry |
      select(any($cleanup[]; .role == "cluster" and .name == $entry.name) | not)] |
    .users = [(.users // [])[] | . as $entry |
      select(any($cleanup[]; .role == "user" and .name == $entry.name) | not)];
  def delete_from_file($p; $index):
    if $index == $p.target then .contexts = [(.contexts // [])[] | select(.name != $p.profile)] else . end |
    delete_resources($p; $index) |
    if ($p.clear_current | index($index)) != null then .["current-context"] = "" else . end;
  def semantic_config:
    .contexts = ((.contexts // []) | sort_by(.name)) |
    .clusters = ((.clusters // []) | sort_by(.name)) |
    .users = ((.users // []) | sort_by(.name)) |
    .["current-context"] = (.["current-context"] // "");
'

k8s_profile_plan_delete() {
  local profile="$1" definitions_count
  k8s_profile_validate_ownership || return 1
  k8s_profile_json_value definitions_count --arg profile "$profile" "$K8S_PROFILE_MODEL_JQ"'
    (definitions(.; "context"; $profile) | length | tostring), "\u0000"
  ' "$K8S_PROFILE_TMP_DIR/inventory.json" || return 1
  if [ "$definitions_count" -eq 0 ]; then
    k8s_profile_error 'selected context no longer exists; retry the command'
    return 1
  fi
  if [ "$definitions_count" -ne 1 ]; then
    k8s_profile_error 'selected context has multiple physical definitions; remove or rename its shadow definitions using kubectl with an explicit --kubeconfig file before retrying delete'
    return 1
  fi
  k8s_profile_jq "$K8S_PROFILE_TMP_DIR/delete-plan.json" 'unable to plan profile deletion' \
    --arg profile "$profile" --slurpfile visible "$K8S_PROFILE_TMP_DIR/visible.json" "$K8S_PROFILE_MODEL_JQ"'
      . as $files | definitions($files; "context"; $profile)[0].index as $target |
      ($visible[0]["current-context"] // "") as $current |
      ($current != "" and $current == $profile) as $is_current |
      ($files | map(. as $file | .config.contexts =
        [entries($file; "context") | select(.name != $profile)])) as $proposed |
      [ ["cluster", "user"][] as $role | $files[] as $file | entries($file; $role) |
        {index:$file.index,name:.name,data:.[$role],role:$role} |
        select(owned(.; $profile; $role)) |
        select((definitions($files; $role; .name) | length) == 1) |
        select((references($proposed; $role; .name) | length) == 0) |
        {index:.index,name:.name,role:.role} ] as $cleanup |
      [$files[] | select((.config["current-context"] // "") != "") |
        select($is_current or .config["current-context"] == $profile) | .index] as $clear_current |
      {profile:$profile,target:$target,is_current:$is_current,cleanup:$cleanup,clear_current:$clear_current,
       expected_current:(if $is_current then "" else $current end),
       write_indexes:([$target, $cleanup[].index, $clear_current[]] | unique | reverse)}
    ' "$K8S_PROFILE_TMP_DIR/inventory.json"
}

k8s_profile_delete_indexes() {
  k8s_profile_jq "$K8S_PROFILE_TMP_DIR/delete-indexes" 'unable to inspect deletion targets' -r \
    '.write_indexes[]' "$K8S_PROFILE_TMP_DIR/delete-plan.json"
}

k8s_profile_preview_delete() {
  local line
  local -a lines=()
  k8s_profile_jq "$K8S_PROFILE_TMP_DIR/delete-preview" 'unable to preview profile deletion' -r "$K8S_PROFILE_DISPLAY_JQ"'
    "Remove context: " + (.profile | display_text),
    "Remove eligible owned clusters: " + ([.cleanup[] | select(.role == "cluster")] | length | tostring),
    "Remove eligible owned users: " + ([.cleanup[] | select(.role == "user")] | length | tostring) + " (inline Tokens included)",
    (.cleanup[] | "  " + .role + ": " + (.name | display_text)),
    "Kubeconfig files changed: " + (.write_indexes | length | tostring),
    "Keep shared/unmanaged, referenced, or ambiguous resources and ALL external Token/CA/certificate/key files.",
    (if .is_current then
       "WARNING: This is the current profile. ALL nonempty current-context values, including hidden different fallbacks, will be cleared. No replacement will be selected."
     else "Current profile: unchanged; only obsolete same-name current-context references are cleared." end)
  ' "$K8S_PROFILE_TMP_DIR/delete-plan.json" || return 1
  while IFS= read -r line; do
    lines+=("$line")
  done <"$K8S_PROFILE_TMP_DIR/delete-preview"
  picotools_ui_summary 'Review Profile Deletion' "${lines[@]}"
  if ! picotools_ui_stderr_is_pretty; then
    printf 'Review Profile Deletion:\n' >&2
    printf '%s\n' "${lines[@]}" >&2
  fi
}

k8s_profile_stage_delete() {
  local index
  k8s_profile_delete_indexes || return 1
  # Descending chain indexes publish low precedence before high precedence.
  # That prevents a cleared effective current context from exposing a fallback.
  while IFS= read -r index; do
    k8s_profile_tx_add_file "$index" || return 1
  done <"$K8S_PROFILE_TMP_DIR/delete-indexes"
  k8s_profile_tx_prepare || return 1
  for index in "${K8S_PROFILE_TX_WRITE_SET[@]}"; do
    k8s_profile_write_config "${K8S_PROFILE_TX_CANDIDATES[$index]}" 'unable to stage profile deletion' \
      --argjson index "$index" --slurpfile plan "$K8S_PROFILE_TMP_DIR/delete-plan.json" "$K8S_PROFILE_DELETE_JQ"'
        delete_from_file($plan[0]; $index)
      ' "${K8S_PROFILE_CHAIN_RAW[$index]}" || return 1
  done
}

k8s_profile_verify_delete() {
  local merged_file="$1" index
  k8s_profile_jq "$K8S_PROFILE_TMP_DIR/deletion-check" 'profile deletion did not preserve the requested cleanup or current context' -e \
    --slurpfile plan "$K8S_PROFILE_TMP_DIR/delete-plan.json" --slurpfile before "$K8S_PROFILE_TMP_DIR/visible.json" "$K8S_PROFILE_DELETE_JQ"'
      $plan[0] as $p |
      ($before[0] | .contexts = [(.contexts // [])[] | select(.name != $p.profile)] |
        delete_resources($p; null) | .["current-context"] = $p.expected_current | semantic_config) == semantic_config
    ' "$merged_file" || return 1
  for index in "${K8S_PROFILE_TX_WRITE_SET[@]}"; do
    k8s_profile_jq "$K8S_PROFILE_TMP_DIR/deletion-file-check" 'profile deletion changed unrelated physical configuration' -e \
      --argjson index "$index" --slurpfile plan "$K8S_PROFILE_TMP_DIR/delete-plan.json" \
      --slurpfile before "$K8S_PROFILE_TMP_DIR/inventory.json" "$K8S_PROFILE_DELETE_JQ"'
        ($before[0][$index].config | delete_from_file($plan[0]; $index) | semantic_config) == semantic_config
      ' "$K8S_PROFILE_TMP_DIR/validated-$index.json" || return 1
  done
}

k8s_profile_delete() {
  local index name display_name confirmation
  k8s_profile_init || return 1
  k8s_profile_snapshot_chain || return 1
  k8s_profile_validate_ownership || return 1
  picotools_ui_section 'Delete Kubernetes Profile'
  picotools_ui_step 1 2 'Select profile'
  k8s_profile_capture_prompt index k8s_profile_select_index || return 1
  k8s_profile_profile_name "$index" name || return 1
  k8s_profile_recheck_chain || return 1
  k8s_profile_display_name "$index" display_name || return 1
  k8s_profile_plan_delete "$name" || return 1
  k8s_profile_delete_indexes || return 1
  # Check every cleanup/current-reference target before asking for consent;
  # tx_prepare repeats the full preflight after consent, before any publication.
  while IFS= read -r index; do
    k8s_profile_preflight_write "${K8S_PROFILE_CHAIN_PATHS[$index]}" || return 1
  done <"$K8S_PROFILE_TMP_DIR/delete-indexes"
  k8s_profile_preview_delete || return 1
  k8s_profile_capture_prompt confirmation k8s_profile_prompt_delete_confirmation "Delete '$display_name'?" || return 1
  if [ "$confirmation" != yes ]; then
    picotools_cancel
    return 1
  fi
  k8s_profile_recheck_chain || return 1
  picotools_ui_step 2 2 'Delete profile and eligible owned resources'
  debug_log 'Staging selected context deletion and approved orphan cleanup'
  k8s_profile_stage_delete || return 1
  k8s_profile_tx_commit k8s_profile_verify_delete || return 1
  picotools_ui_status ok "Deleted profile '$display_name'"
  printf "Deleted profile '%s'.\n" "$display_name"
}

# Switching must preserve every physical field other than current-context,
# including hidden definitions and raw credentials that merged view redacts.
K8S_PROFILE_USE_JQ='
  def semantic_config:
    .contexts = ((.contexts // []) | sort_by(.name)) |
    .clusters = ((.clusters // []) | sort_by(.name)) |
    .users = ((.users // []) | sort_by(.name)) |
    .["current-context"] = (.["current-context"] // "");
'

k8s_profile_plan_use() {
  local profile="$1" definitions_count
  k8s_profile_validate_ownership || return 1
  k8s_profile_json_value definitions_count --arg profile "$profile" "$K8S_PROFILE_MODEL_JQ"'
    (definitions(.; "context"; $profile) | length | tostring), "\u0000"
  ' "$K8S_PROFILE_TMP_DIR/inventory.json" || return 1
  if [ "$definitions_count" -eq 0 ]; then
    k8s_profile_error 'profile does not exist; use list to inspect available contexts'
    return 1
  fi
  if [ "$definitions_count" -ne 1 ]; then
    k8s_profile_error 'selected context has multiple physical definitions; remove or rename its shadow definitions using kubectl with an explicit --kubeconfig file before retrying use'
    return 1
  fi
  # A nonempty value in the first existing member outranks all lower fallbacks.
  # No context/resources are copied, and no missing chain member is created.
  k8s_profile_jq "$K8S_PROFILE_TMP_DIR/use-plan.json" 'unable to plan context switching' \
    --arg profile "$profile" --slurpfile visible "$K8S_PROFILE_TMP_DIR/visible.json" '
      {profile:$profile,target:([.[] | select(.existed) | .index][0]),
       is_current:(($visible[0]["current-context"] // "") == $profile)}
    ' "$K8S_PROFILE_TMP_DIR/inventory.json"
}

k8s_profile_stage_use() {
  local target
  k8s_profile_json_value target '(.target | tostring), "\u0000"' "$K8S_PROFILE_TMP_DIR/use-plan.json" || return 1
  k8s_profile_tx_add_file "$target" || return 1
  k8s_profile_tx_prepare || return 1
  k8s_profile_write_config "${K8S_PROFILE_TX_CANDIDATES[$target]}" 'unable to stage context switching' \
    --slurpfile plan "$K8S_PROFILE_TMP_DIR/use-plan.json" '
      .["current-context"] = $plan[0].profile
    ' "${K8S_PROFILE_CHAIN_RAW[$target]}"
}

k8s_profile_verify_use() {
  local merged_file="$1" target
  k8s_profile_jq "$K8S_PROFILE_TMP_DIR/use-check" 'context switching changed unrelated configuration or did not activate the requested profile' -e \
    --slurpfile plan "$K8S_PROFILE_TMP_DIR/use-plan.json" --slurpfile before "$K8S_PROFILE_TMP_DIR/visible.json" "$K8S_PROFILE_USE_JQ"'
      ($before[0] | .["current-context"] = $plan[0].profile | semantic_config) == semantic_config
    ' "$merged_file" || return 1
  k8s_profile_json_value target '(.target | tostring), "\u0000"' "$K8S_PROFILE_TMP_DIR/use-plan.json" || return 1
  k8s_profile_jq "$K8S_PROFILE_TMP_DIR/use-file-check" 'context switching changed unrelated physical configuration' -e \
    --argjson target "$target" --slurpfile plan "$K8S_PROFILE_TMP_DIR/use-plan.json" \
    --slurpfile before "$K8S_PROFILE_TMP_DIR/inventory.json" "$K8S_PROFILE_USE_JQ"'
      ($before[0][$target].config | .["current-context"] = $plan[0].profile | semantic_config) == semantic_config
    ' "$K8S_PROFILE_TMP_DIR/validated-$target.json"
}

k8s_profile_use() {
  local profile="${1:-}" index exact_name display_name is_current
  k8s_profile_init || return 1
  k8s_profile_snapshot_chain || return 1
  if [ "$#" -eq 0 ]; then
    k8s_profile_capture_prompt index k8s_profile_select_index || return 1
    k8s_profile_profile_name "$index" exact_name || return 1
  else
    k8s_profile_find_profile_index "$profile" index || return 1
    if [ "$index" -eq 0 ]; then
      k8s_profile_error 'profile does not exist; use list to inspect available contexts'
      return 1
    fi
    k8s_profile_profile_name "$index" exact_name || return 1
    # jq can replace invalid native argument bytes with U+FFFD; never switch to
    # that different, valid context. External UTF-8 names need no create-name rule.
    if [ "$profile" != "$exact_name" ]; then
      k8s_profile_error 'profile name must match an existing context exactly (valid UTF-8)'
      return 1
    fi
  fi
  if [ -z "$exact_name" ]; then
    k8s_profile_error 'an empty context name cannot be activated'
    return 1
  fi
  k8s_profile_recheck_chain || return 1
  k8s_profile_display_name "$index" display_name || return 1
  k8s_profile_plan_use "$exact_name" || return 1
  k8s_profile_recheck_chain || return 1
  k8s_profile_json_value is_current '(.is_current | tostring), "\u0000"' "$K8S_PROFILE_TMP_DIR/use-plan.json" || return 1
  if [ "$is_current" = true ]; then
    k8s_profile_recheck_chain || return 1
    printf "Profile '%s' is already current.\n" "$display_name"
    return 0
  fi
  debug_log 'Staging current-context only; profile settings and credentials remain unchanged'
  k8s_profile_stage_use || return 1
  k8s_profile_tx_commit k8s_profile_verify_use || return 1
  printf "Switched to profile '%s'.\n" "$display_name"
}
