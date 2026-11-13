#!/usr/bin/env bash
# shellcheck disable=SC2016 # jq owns the variables in single-quoted programs.

if [ "${PICOTOOLS_K8S_PROFILE_MODEL_SH_LOADED:-0}" -eq 1 ]; then
  return 0
fi
PICOTOOLS_K8S_PROFILE_MODEL_SH_LOADED=1

# Static jq helpers only. Configuration/token data always enters via private
# files, never interpolation into jq programs or --arg/--argjson secret values.
K8S_PROFILE_MODEL_JQ='
  def collection($role): if $role == "context" then "contexts" elif $role == "cluster" then "clusters" else "users" end;
  def entries($file; $role): ($file.config[collection($role)] // [])[];
  def definitions($files; $role; $name):
    [$files[] as $file | entries($file; $role) | select(.name == $name) |
     {index:$file.index, directory:$file.directory, name:.name, data:.[$role]}];
  def references($files; $role; $name):
    [$files[] as $file | entries($file; "context") | select((.context[$role] // "") == $name) |
     {index:$file.index, name:.name}];
  def ownership($data): [($data.extensions // [])[] | select(.name == "picotools.k8s-profile")];
  def valid_owned_name($name; $profile; $role):
    if $role == "context" then $name == $profile
    else ("k8s-profile:" + $profile + ":" + $role + ":") as $prefix |
      ($name | startswith($prefix)) and ($name[($prefix | length):] | test("^[1-9][0-9]*$")) end;
  def valid_metadata($entry; $role):
    ownership($entry[$role]) as $owners |
    if ($owners | length) == 0 then true
    elif ($owners | length) != 1 then false
    else $owners[0].extension as $m |
      ($m | type == "object") and $m.version == 1 and $m.role == $role and
      ($m.profile | type == "string") and
      ($m.profile | contains("\u0000") | not) and valid_owned_name($entry.name; $m.profile; $role)
    end;
  def owned($definition; $profile; $role):
    ownership($definition.data) as $owners |
    ($owners | length) == 1 and $owners[0].extension.version == 1 and
    $owners[0].extension.profile == $profile and $owners[0].extension.role == $role and
    valid_owned_name($definition.name; $profile; $role);
  def marker($profile; $role):
    {name:"picotools.k8s-profile", extension:{version:1,profile:$profile,role:$role}};
  def with_marker($profile; $role):
    .extensions = (((.extensions // []) | map(select(.name != "picotools.k8s-profile"))) + [marker($profile; $role)]);
  def reusable($files; $defs; $profile; $role; $target):
    if ($defs | length) != 1 then false
    else $defs[0] as $d | references($files; $role; $d.name) as $refs |
      $d.index == $target and owned($d; $profile; $role) and ($refs | length) == 1 and
      $refs[0].index == $target and $refs[0].name == $profile end;
  def allocate($files; $profile; $role):
    [$files[] | entries(.; $role) | .name] as $names |
    first(range(1; ($names | length) + 2) | "k8s-profile:" + $profile + ":" + $role + ":" + tostring |
      . as $candidate | select(($names | index($candidate)) == null));
  def incompatible_bearer_auth:
    .exec != null or .["auth-provider"] != null or
    any([.username, .password, .["client-certificate"], .["client-certificate-data"],
         .["client-key"], .["client-key-data"]][]; . != null and . != "");
  def target_index($files; $profile):
    definitions($files; "context"; $profile) as $contexts |
    if ($contexts | length) > 0 then $contexts[0].index
    else ([$files[] | select(.existed) | .index][0] // $files[-1].index) end;
  def rebase($source_directory; $target_directory; $keys):
    if $source_directory == $target_directory then .
    else reduce $keys[] as $key (.;
      if ((.[$key] // "") | length) > 0 and (.[$key] | startswith("/") | not)
      then .[$key] = ($source_directory + .[$key]) else . end) end;
'

k8s_profile_validate_ownership() {
  k8s_profile_jq "$K8S_PROFILE_TMP_DIR/ownership-check" 'unsupported or inconsistent picotools.k8s-profile ownership metadata' -e \
    "$K8S_PROFILE_MODEL_JQ"'
      all(.[];
        ([((.config.extensions // [])[]), ((.config.preferences.extensions // [])[])] |
          all(.name != "picotools.k8s-profile")) and
        all(entries(.; "context"); valid_metadata(.; "context")) and
        all(entries(.; "cluster"); valid_metadata(.; "cluster")) and
        all(entries(.; "user"); valid_metadata(.; "user")))
    ' "$K8S_PROFILE_TMP_DIR/inventory.json"
}

k8s_profile_target_index() {
  local profile="$1" result_var="$2"
  k8s_profile_json_value "$result_var" --arg profile "$profile" "$K8S_PROFILE_MODEL_JQ"'
    (target_index(.; $profile) | tostring), "\u0000"
  ' "$K8S_PROFILE_TMP_DIR/inventory.json"
}

# Reusable create/update planner: name is stable; only the true fields change.
# It plans cleanup against ALL physical contexts, including hidden definitions.
k8s_profile_plan_change() {
  local profile="$1" server="$2" server_change="$3" token_change="$4"
  local namespace="${5:-}" namespace_change="${6:-false}"
  if [ "$server_change" = true ]; then
    k8s_profile_validate_server "$server" || return 1
  fi
  if [ "$namespace_change" = true ]; then
    k8s_profile_validate_namespace "$namespace" || return 1
  fi
  k8s_profile_validate_ownership || return 1
  k8s_profile_jq "$K8S_PROFILE_TMP_DIR/change-plan.json" 'unable to plan profile change (required cluster information or compatible bearer authentication is missing)' \
    --arg profile "$profile" --arg server "$server" --argjson server_change "$server_change" --argjson token_change "$token_change" \
    --arg namespace "$namespace" --argjson namespace_change "$namespace_change" \
    "$K8S_PROFILE_MODEL_JQ"'
      . as $files | target_index($files; $profile) as $target |
      definitions($files; "context"; $profile) as $contexts |
      ($contexts[0].data // {}) as $old_context |
      definitions($files; "cluster"; ($old_context.cluster // "")) as $clusters |
      definitions($files; "user"; ($old_context.user // "")) as $users |
      if $token_change and (($users[0].data // {}) | incompatible_bearer_auth) then
        error("incompatible authentication")
      elif ($server_change | not) and (($clusters[0].data.server // "") | length) == 0 then
        error("missing required cluster information")
      else
        reusable($files; $clusters; $profile; "cluster"; $target) as $reuse_cluster |
        reusable($files; $users; $profile; "user"; $target) as $reuse_user |
        (if $server_change then
           if $reuse_cluster then $clusters[0].name else allocate($files; $profile; "cluster") end
         else ($old_context.cluster // "") end) as $cluster_name |
        (if $token_change then
           if $reuse_user then $users[0].name else allocate($files; $profile; "user") end
         else ($old_context.user // "") end) as $user_name |
        ($old_context | .cluster = $cluster_name | .user = $user_name |
         (if $namespace_change then .namespace = $namespace else . end) |
         with_marker($profile; "context")) as $context |
        ($files | map(. as $file | .config.contexts =
          [entries($file; "context") | if $file.index == $target and .name == $profile then .context = $context else . end]) |
          if ($contexts | length) == 0 then
            map(if .index == $target then .config.contexts += [{name:$profile,context:$context}] else . end)
          else . end) as $proposed |
        {profile:$profile,target:$target,directory:$files[$target].directory,context:$context,
         server_change:$server_change,token_change:$token_change,namespace_change:$namespace_change,
         expected_namespace:(if $namespace_change then $namespace else ($old_context.namespace // "") end),
         cluster_name:$cluster_name,user_name:$user_name,
         cluster_source:($clusters[0] // {data:{},directory:$files[$target].directory}),
         user_source:($users[0] // {data:{},directory:$files[$target].directory}),
         expected_server:(if $server_change then $server else $clusters[0].data.server end),
         cleanup:[ ["cluster", "user"][] as $role | $files[] as $file | entries($file; $role) |
           {index:$file.index,name:.name,data:.[$role],role:$role} |
           select(owned(.; $profile; $role)) |
           select((definitions($files; $role; .name) | length) == 1) |
           select((references($proposed; $role; .name) | length) == 0) |
           {index:.index,name:.name,role:.role} ]}
      end
    ' "$K8S_PROFILE_TMP_DIR/inventory.json"
}

k8s_profile_stage_change() {
  local token_file="$1" target index edited
  local -a cleanup_indexes=()
  # Referenced by the verifier after publication; it holds a path, not a token.
  K8S_PROFILE_CHANGE_TOKEN_FILE="$token_file"
  if [ -n "$token_file" ]; then
    k8s_profile_validate_token_file "$token_file" || return 1
  fi
  if [ -z "$token_file" ]; then
    token_file="$K8S_PROFILE_TMP_DIR/empty-token-input"
    : >"$token_file"
  fi
  k8s_profile_json_value target '(.target | tostring), "\u0000"' "$K8S_PROFILE_TMP_DIR/change-plan.json" || return 1
  k8s_profile_tx_add_file "$target" || return 1
  k8s_profile_jq "$K8S_PROFILE_TMP_DIR/cleanup-indexes" 'unable to inspect orphan cleanup' -r '.cleanup | map(.index) | unique[]' "$K8S_PROFILE_TMP_DIR/change-plan.json" || return 1
  while IFS= read -r index; do
    cleanup_indexes+=("$index")
    k8s_profile_tx_add_file "$index" || return 1
  done <"$K8S_PROFILE_TMP_DIR/cleanup-indexes"
  k8s_profile_tx_prepare || return 1
  k8s_profile_write_config "${K8S_PROFILE_TX_CANDIDATES[$target]}" 'unable to build profile candidate' \
    --slurpfile plan "$K8S_PROFILE_TMP_DIR/change-plan.json" --rawfile token "$token_file" \
    "$K8S_PROFILE_MODEL_JQ"'
      $plan[0] as $p |
      .contexts = (((.contexts // []) | map(select(.name != $p.profile))) + [{name:$p.profile,context:$p.context}]) |
      if $p.server_change then
        ($p.cluster_source.data | .server = $p.expected_server |
          rebase($p.cluster_source.directory; $p.directory; ["certificate-authority"]) |
          with_marker($p.profile; "cluster")) as $cluster |
        .clusters = (((.clusters // []) | map(select(.name != $p.cluster_name))) + [{name:$p.cluster_name,cluster:$cluster}])
      else . end |
      if $p.token_change then
        ($p.user_source.data |
          rebase($p.user_source.directory; $p.directory; ["client-certificate", "client-key", "tokenFile"]) |
          .token = $token | del(.tokenFile) | with_marker($p.profile; "user")) as $user |
        .users = (((.users // []) | map(select(.name != $p.user_name))) + [{name:$p.user_name,user:$user}])
      else . end
    ' "${K8S_PROFILE_CHAIN_RAW[$target]}" || return 1
  for index in "${cleanup_indexes[@]}"; do
    edited="$K8S_PROFILE_TMP_DIR/cleaned-$index.json"
    k8s_profile_write_config "$edited" 'unable to stage owned orphan cleanup' \
      --argjson index "$index" --slurpfile plan "$K8S_PROFILE_TMP_DIR/change-plan.json" '
        [$plan[0].cleanup[] | select(.index == $index)] as $cleanup |
        .clusters = [(.clusters // [])[] | . as $entry | select(any($cleanup[]; .role == "cluster" and .name == $entry.name) | not)] |
        .users = [(.users // [])[] | . as $entry | select(any($cleanup[]; .role == "user" and .name == $entry.name) | not)]
      ' "${K8S_PROFILE_TX_CANDIDATES[$index]}" || return 1
    if ! cp -- "$edited" "${K8S_PROFILE_TX_CANDIDATES[$index]}" >"$K8S_PROFILE_TMP_DIR/operation-output" 2>"$K8S_PROFILE_TMP_DIR/diagnostics"; then
      k8s_profile_error 'unable to finish staging owned orphan cleanup'
      return 1
    fi
  done
}

k8s_profile_verify_change() {
  local merged_file="$1" target token_change
  k8s_profile_jq "$K8S_PROFILE_TMP_DIR/registration-check" 'profile registration did not preserve the requested references or current context' -e \
    --slurpfile plan "$K8S_PROFILE_TMP_DIR/change-plan.json" --slurpfile before "$K8S_PROFILE_TMP_DIR/visible.json" '
      $plan[0] as $p |
      [.contexts[]? | select(.name == $p.profile)] as $contexts |
      [.clusters[]? | select(.name == $p.cluster_name)] as $clusters |
      [.users[]? | select(.name == $p.user_name)] as $users |
      ($contexts | length) == 1 and $contexts[0].context.cluster == $p.cluster_name and
      $contexts[0].context.user == $p.user_name and
      (($contexts[0].context.namespace // "") == $p.expected_namespace) and
      ($clusters | length) == 1 and
      $clusters[0].cluster.server == $p.expected_server and
      (($p.token_change | not) or (($users | length) == 1 and (($users[0].user.token // "") | length) > 0)) and
      (.["current-context"] // "") == ($before[0]["current-context"] // "")
    ' "$merged_file" || return 1
  k8s_profile_json_value token_change '(.token_change | tostring), "\u0000"' "$K8S_PROFILE_TMP_DIR/change-plan.json" || return 1
  if [ "$token_change" = true ]; then
    k8s_profile_json_value target '(.target | tostring), "\u0000"' "$K8S_PROFILE_TMP_DIR/change-plan.json" || return 1
    k8s_profile_jq "$K8S_PROFILE_TMP_DIR/token-check" 'candidate Token registration failed' -e \
      --slurpfile plan "$K8S_PROFILE_TMP_DIR/change-plan.json" --rawfile token "$K8S_PROFILE_CHANGE_TOKEN_FILE" '
        $plan[0] as $p | [.users[]? | select(.name == $p.user_name)] as $users |
        ($users | length) == 1 and $users[0].user.token == $token and $users[0].user.tokenFile == null
      ' "$K8S_PROFILE_TMP_DIR/validated-$target.json" || return 1
  fi
}
