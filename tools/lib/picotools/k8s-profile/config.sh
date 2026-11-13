#!/usr/bin/env bash
# shellcheck disable=SC2016 # Single-quoted jq programs use jq variables, not shell expansion.

if [ "${PICOTOOLS_K8S_PROFILE_CONFIG_SH_LOADED:-0}" -eq 1 ]; then
  return 0
fi
PICOTOOLS_K8S_PROFILE_CONFIG_SH_LOADED=1

K8S_PROFILE_CHAIN_PATHS=()
K8S_PROFILE_CHAIN_LOAD_PATHS=()
K8S_PROFILE_CHAIN_EXISTED=()
K8S_PROFILE_CHAIN_FINGERPRINTS=()
K8S_PROFILE_CHAIN_PARENT_STATES=()
K8S_PROFILE_CHAIN_BACKUPS=()
K8S_PROFILE_CHAIN_RAW=()

# JSON escapes C0 controls; additionally escape DEL/C1 and table separators.
# Labels are never decoded back into identities: menus return numeric indexes.
K8S_PROFILE_DISPLAY_JQ='
  def display_text:
    tojson | .[1:-1] | explode | map(
      if . >= 127 and . <= 159 then . as $code |
        "0123456789abcdef" as $hex |
        (($code / 16) | floor) as $high | ($code % 16) as $low |
        "\\u00" + $hex[$high:$high + 1] + $hex[$low:$low + 1]
      else [.] | implode end) | join("") | gsub("\\|"; "\\u007c");
'

# kubectl's YAML/JSON loader rejects literal DEL/C1 and U+2028/U+2029 in object
# keys (scalar separators do load), but also rejects escaped non-BMP surrogate
# pairs. Escape those BMP characters after JSON encoding, keeping other UTF-8
# literal. This serializer is for config objects, not raw selection output.
k8s_profile_write_config() {
  local output="$1" message="$2"
  shift 2
  k8s_profile_jq "$K8S_PROFILE_TMP_DIR/config-serialization.json" "$message" "$@" || return 1
  k8s_profile_jq "$output" "$message" -j '
    tojson | explode | map(
      if . >= 127 and . <= 159 then . as $code |
        "0123456789abcdef" as $hex |
        (($code / 16) | floor) as $high | ($code % 16) as $low |
        "\\u00" + $hex[$high:$high + 1] + $hex[$low:$low + 1]
      elif . == 8232 then "\\u2028"
      elif . == 8233 then "\\u2029"
      else [.] | implode end) | join("")
  ' "$K8S_PROFILE_TMP_DIR/config-serialization.json"
}

k8s_profile_validate_config_json() {
  k8s_profile_jq "$K8S_PROFILE_TMP_DIR/schema-check" 'kubectl returned malformed configuration' -e '
    def entries($key; $role):
      (.[$key] == null or (.[$key] | type == "array")) and
      all(.[$key][]?;
        (.name | type == "string") and (.name | contains("\u0000") | not) and
        (.[$role] | type == "object"));
    type == "object" and .kind == "Config" and .apiVersion == "v1" and
    entries("contexts"; "context") and entries("clusters"; "cluster") and entries("users"; "user") and
    ((.["current-context"] // "") | type == "string") and
    all(.contexts[]?;
      ((.context.cluster // "") | type == "string") and
      ((.context.user // "") | type == "string") and
      ((.context.cluster // "") | contains("\u0000") | not) and
      ((.context.user // "") | contains("\u0000") | not)) and
    all(.clusters[]?; ((.cluster.server // "") | type == "string"))
  ' "$1"
}

k8s_profile_project_config() {
  local source_file="$1" output="$2"
  k8s_profile_validate_config_json "$source_file" || return 1
  k8s_profile_jq "$output" 'unable to project profile references' '
    def public_server:
      if startswith("https://") or startswith("http://") then
        sub("://[^/]*@"; "://[redacted]@") | sub("[?#].*$"; "")
      else "" end;
    . as $config | (.["current-context"] // "") as $current |
    {current: $current, profiles: [(.contexts // [])[] |
      . as $entry |
      ([($config.clusters // [])[] | select(.name == ($entry.context.cluster // ""))][0] // null) as $cluster |
      ([($config.users // [])[] | select(.name == ($entry.context.user // ""))][0] // null) as $user |
      {name: .name, cluster: (.context.cluster // ""), user: (.context.user // ""),
       cluster_found: ($cluster != null), user_found: ($user != null),
        server: (($cluster.cluster.server // "") | public_server), current: ($current != "" and .name == $current)}
    ] | sort_by(.name)}
  ' "$source_file"
}

# Read-only discovery permits regular symlinks, hardlinks, and aliases, as
# kubectl does. Reject only existing nonregular inputs before kubectl can block
# opening (for example) a FIFO. Separator-only chains intentionally stay empty.
k8s_profile_check_read_inputs() {
  local chain="${KUBECONFIG:-}" path
  local -a paths=()
  if [ -z "$chain" ]; then
    if [ -z "${HOME:-}" ]; then
      k8s_profile_error 'HOME is required for the default kubeconfig'
      return 1
    fi
    # The default is ONE literal filename, even when HOME contains a colon.
    paths=("$HOME/.kube/config")
  else
    while true; do
      path=${chain%%:*}
      [ -z "$path" ] || paths+=("$path")
      [[ "$chain" == *:* ]] || break
      chain=${chain#*:}
    done
  fi
  for path in "${paths[@]}"; do
    if [ -n "$path" ] && { [ -e "$path" ] || [ -L "$path" ]; } && [ ! -f "$path" ]; then
      k8s_profile_error 'unsafe kubeconfig input (nonregular file)'
      return 1
    fi
  done
}

k8s_profile_read_visible() {
  k8s_profile_check_read_inputs || return 1
  k8s_profile_kubectl "$K8S_PROFILE_TMP_DIR/visible.json" 'unable to read kubectl configuration' config view -o json || return 1
  k8s_profile_project_config "$K8S_PROFILE_TMP_DIR/visible.json" "$K8S_PROFILE_TMP_DIR/profiles.json"
}

k8s_profile_print_profiles() {
  local row
  local -a rows=()
  k8s_profile_jq "$K8S_PROFILE_TMP_DIR/rows" 'unable to format profiles' -r "$K8S_PROFILE_DISPLAY_JQ"'
    def display: if . == "" then "-" else display_text end;
    .profiles | to_entries[] |
    [(.key + 1 | tostring), (.value.name | display), (.value.server | display),
     (if .value.cluster_found then .value.cluster | display else "-" end),
     (if .value.user_found then .value.user | display else "-" end),
     (if .value.current then "yes" else "no" end)] | join("\t")
  ' "$K8S_PROFILE_TMP_DIR/profiles.json" || return 1
  while IFS= read -r row; do
    rows+=("$row")
  done <"$K8S_PROFILE_TMP_DIR/rows"
  debug_log "Listing ${#rows[@]} profile(s)"
  if [ "${#rows[@]}" -eq 0 ]; then
    printf 'No Kubernetes profiles found.\n'
    return 0
  fi
  picotools_print_table $'#\tName\tServer\tCluster\tUser\tCurrent' "${rows[@]}"
}

k8s_profile_find_profile_index() {
  local name="$1" result_var="$2"
  k8s_profile_json_value "$result_var" --arg name "$name" '
    ([.profiles | to_entries[] | select(.value.name == $name) | .key + 1][0] // 0 | tostring), "\u0000"
  ' "$K8S_PROFILE_TMP_DIR/profiles.json"
}

k8s_profile_profile_name() {
  local index="$1" result_var="$2"
  k8s_profile_json_value "$result_var" --argjson index "$index" '.profiles[$index - 1].name, "\u0000"' "$K8S_PROFILE_TMP_DIR/profiles.json"
}

# The selection returns an index, never an escaped display name. profile_name
# retrieves even option-like/quoted/newline-bearing identities without loss.
k8s_profile_select_index() {
  local option selection status
  local -a options=()
  k8s_profile_jq "$K8S_PROFILE_TMP_DIR/options" 'unable to format profile selection' -r "$K8S_PROFILE_DISPLAY_JQ"'
    .profiles[].name | display_text
  ' "$K8S_PROFILE_TMP_DIR/profiles.json" || return 1
  while IFS= read -r option; do
    options+=("$option")
  done <"$K8S_PROFILE_TMP_DIR/options"
  if [ "${#options[@]}" -eq 0 ]; then
    printf 'No Kubernetes profiles found.\n' >&2
    return 1
  fi
  if k8s_profile_capture_prompt selection k8s_profile_prompt_select_index Profiles 'Select profile' '' false "${options[@]}"; then
    printf '%s\n' "$selection"
    return 0
  else
    status=$?
  fi
  if [ "$status" -eq 2 ]; then
    picotools_cancel
  fi
  return 1
}

# Native filenames may contain non-UTF-8 bytes which jq silently replaces in
# --arg values. Mutation origins must survive JSON encoding byte-for-byte before
# inventory/rebase/recovery uses them. This is NOT the Token whitespace policy.
k8s_profile_validate_path_encoding() {
  if ! { command printf '%s' "$1" >"$K8S_PROFILE_TMP_DIR/path-input"; } 2>"$K8S_PROFILE_TMP_DIR/diagnostics"; then
    k8s_profile_error 'unable to inspect mutation path encoding'
    return 1
  fi
  k8s_profile_jq "$K8S_PROFILE_TMP_DIR/path-encoded.json" 'unable to inspect mutation path encoding' \
    -n --rawfile path "$K8S_PROFILE_TMP_DIR/path-input" '$path' || return 1
  k8s_profile_jq "$K8S_PROFILE_TMP_DIR/path-decoded" 'unable to inspect mutation path encoding' \
    -j '.' "$K8S_PROFILE_TMP_DIR/path-encoded.json" || return 1
  if ! cmp -s -- "$K8S_PROFILE_TMP_DIR/path-input" "$K8S_PROFILE_TMP_DIR/path-decoded" 2>"$K8S_PROFILE_TMP_DIR/diagnostics"; then
    k8s_profile_error 'mutation paths, origins, and recovery workspaces must be valid UTF-8; choose UTF-8 paths'
    return 1
  fi
}

k8s_profile_load_chain_paths() {
  local chain="${KUBECONFIG:-}" entry absolute cwd previous key old_key
  local -a entries=() keys=() components=() clean=()
  K8S_PROFILE_CHAIN_PATHS=()
  K8S_PROFILE_CHAIN_LOAD_PATHS=()
  # Backups/candidates/recovery paths append only ASCII names to these checked
  # roots. Do not let an invalid workspace produce lossy JSON recovery metadata.
  k8s_profile_validate_path_encoding "$K8S_PROFILE_TMP_DIR" || return 1
  if [ -z "$chain" ]; then
    if [ -z "${HOME:-}" ]; then
      k8s_profile_error 'HOME is required for the default kubeconfig'
      return 1
    fi
    entries=("$HOME/.kube/config")
  else
    while true; do
      entry=${chain%%:*}
      if [ -n "$entry" ]; then
        entries+=("$entry")
      fi
      [[ "$chain" == *:* ]] || break
      chain=${chain#*:}
    done
  fi
  if [ "${#entries[@]}" -eq 0 ]; then
    k8s_profile_error 'KUBECONFIG has no file paths'
    return 1
  fi
  cwd=$(pwd -P)
  local -a seen=()
  for entry in "${entries[@]}"; do
    local duplicate=false
    for previous in "${seen[@]}"; do
      if [ "$previous" = "$entry" ]; then
        duplicate=true
        break
      fi
    done
    [ "$duplicate" = false ] || continue
    seen+=("$entry")
    absolute="$entry"
    if [[ "$absolute" != /* ]]; then
      absolute="$cwd/$absolute"
    fi
    k8s_profile_validate_path_encoding "$entry" || return 1
    k8s_profile_validate_path_encoding "$absolute" || return 1
    # Inspect the unnormalised ancestors first so /symlink/../file cannot hide
    # a symlink. Distinct lexical aliases are rejected, not silently coalesced.
    k8s_profile_check_ancestors "$absolute" false || return 1
    IFS=/ read -r -a components <<<"$absolute"
    clean=()
    for previous in "${components[@]}"; do
      case "$previous" in
      '' | .) ;;
      ..)
        if [ "${#clean[@]}" -gt 0 ]; then
          unset "clean[$((${#clean[@]} - 1))]"
        fi
        ;;
      *) clean+=("$previous") ;;
      esac
    done
    key="/$(
      IFS=/
      printf '%s' "${clean[*]}"
    )"
    for old_key in "${keys[@]}"; do
      if [ "$key" = "$old_key" ]; then
        k8s_profile_error 'distinct kubeconfig paths alias the same file'
        return 1
      fi
    done
    keys+=("$key")
    K8S_PROFILE_CHAIN_PATHS+=("$absolute")
    K8S_PROFILE_CHAIN_LOAD_PATHS+=("$entry")
  done
}

k8s_profile_snapshot_chain() {
  local index path before after backup raw parent_state file_id other_id backup_digest
  local -a index_files=() file_ids=()
  k8s_profile_load_chain_paths || return 1
  K8S_PROFILE_CHAIN_EXISTED=()
  K8S_PROFILE_CHAIN_FINGERPRINTS=()
  K8S_PROFILE_CHAIN_PARENT_STATES=()
  K8S_PROFILE_CHAIN_BACKUPS=()
  K8S_PROFILE_CHAIN_RAW=()
  for index in "${!K8S_PROFILE_CHAIN_PATHS[@]}"; do
    path=${K8S_PROFILE_CHAIN_PATHS[$index]}
    before=$(k8s_profile_file_fingerprint "$path") || return 1
    parent_state=$(k8s_profile_parent_state "$path") || return 1
    backup="$K8S_PROFILE_TMP_DIR/backup-$index"
    raw="$K8S_PROFILE_TMP_DIR/raw-$index.json"
    if [ "$before" = missing ]; then
      K8S_PROFILE_CHAIN_EXISTED+=(false)
      : >"$backup"
    else
      K8S_PROFILE_CHAIN_EXISTED+=(true)
      file_id=$(stat --printf='%d:%i' -- "$path" 2>"$K8S_PROFILE_TMP_DIR/diagnostics") || return 1
      for other_id in "${file_ids[@]}"; do
        if [ "$file_id" = "$other_id" ]; then
          k8s_profile_error 'distinct kubeconfig paths alias the same physical file'
          return 1
        fi
      done
      file_ids+=("$file_id")
      if ! cp -- "$path" "$backup" >"$K8S_PROFILE_TMP_DIR/operation-output" 2>"$K8S_PROFILE_TMP_DIR/diagnostics"; then
        k8s_profile_error 'unable to snapshot kubeconfig'
        return 1
      fi
    fi
    if ! chmod 600 -- "$backup" >"$K8S_PROFILE_TMP_DIR/operation-output" 2>"$K8S_PROFILE_TMP_DIR/diagnostics"; then
      k8s_profile_error 'unable to secure kubeconfig snapshot'
      return 1
    fi
    after=$(k8s_profile_file_fingerprint "$path") || return 1
    if [ "$before" != "$after" ]; then
      k8s_profile_error 'kubeconfig changed during snapshot; retry the command'
      return 1
    fi
    if [ "$before" != missing ]; then
      backup_digest=$(sha256sum <"$backup" 2>"$K8S_PROFILE_TMP_DIR/diagnostics") || return 1
      if [ "${backup_digest%% *}" != "${before##*:}" ]; then
        k8s_profile_error 'kubeconfig snapshot did not match the checked live contents'
        return 1
      fi
    fi
    k8s_profile_kubectl "$raw" 'unable to read a physical kubeconfig snapshot' "--kubeconfig=$backup" config view --raw --merge=false -o json || return 1
    k8s_profile_validate_config_json "$raw" || return 1
    K8S_PROFILE_CHAIN_FINGERPRINTS+=("$before")
    K8S_PROFILE_CHAIN_PARENT_STATES+=("$parent_state")
    K8S_PROFILE_CHAIN_BACKUPS+=("$backup")
    K8S_PROFILE_CHAIN_RAW+=("$raw")
    index_files+=("$K8S_PROFILE_TMP_DIR/file-$index.json")
    k8s_profile_jq "${index_files[$index]}" 'unable to index physical kubeconfig' -n \
      --argjson index "$index" --arg path "$path" --arg directory "${path%/*}/" \
      --argjson existed "${K8S_PROFILE_CHAIN_EXISTED[$index]}" --slurpfile config "$raw" \
      '{index:$index,path:$path,directory:$directory,existed:$existed,config:$config[0]}' || return 1
  done
  k8s_profile_jq "$K8S_PROFILE_TMP_DIR/inventory.json" 'unable to index the kubeconfig chain' -s '.' "${index_files[@]}" || return 1
  k8s_profile_read_visible || return 1
  k8s_profile_recheck_chain
}

k8s_profile_recheck_chain() {
  local index current parents
  for index in "${!K8S_PROFILE_CHAIN_PATHS[@]}"; do
    current=$(k8s_profile_file_fingerprint "${K8S_PROFILE_CHAIN_PATHS[$index]}") || return 1
    parents=$(k8s_profile_parent_state "${K8S_PROFILE_CHAIN_PATHS[$index]}") || return 1
    if [ "$current" != "${K8S_PROFILE_CHAIN_FINGERPRINTS[$index]}" ] || [ "$parents" != "${K8S_PROFILE_CHAIN_PARENT_STATES[$index]}" ]; then
      k8s_profile_error 'kubeconfig changed since it was read; retry the command'
      return 1
    fi
  done
}

# Used by transaction validation. Every write-set member is replaced with its
# same-directory candidate; untouched physical files remain in loading order.
k8s_profile_read_substituted_chain() {
  local output="$1" index path candidate chain=''
  local -a paths=()
  for index in "${!K8S_PROFILE_CHAIN_PATHS[@]}"; do
    path=${K8S_PROFILE_CHAIN_LOAD_PATHS[$index]}
    candidate=${K8S_PROFILE_TX_CANDIDATES[$index]:-}
    if [ -n "$candidate" ]; then
      # Retain the loading spelling: an absolute candidate beneath a colon-
      # containing cwd is NOT representable in a colon-separated chain.
      if [[ "$path" == */* ]]; then
        path="${path%/*}/${candidate##*/}"
      else
        path="./${candidate##*/}"
      fi
    fi
    paths+=("$path")
  done
  if [ "${#paths[@]}" -eq 1 ]; then
    k8s_profile_kubectl "$output" 'staged kubeconfig chain is invalid' "--kubeconfig=${paths[0]}" config view -o json
  else
    chain=$(
      IFS=:
      printf '%s' "${paths[*]}"
    )
    if ! KUBECONFIG="$chain" KUBECTL_KUBERC=false kubectl config view -o json >"$output" 2>"$K8S_PROFILE_TMP_DIR/diagnostics"; then
      k8s_profile_error 'staged kubeconfig chain is invalid'
      return 1
    fi
  fi
}
