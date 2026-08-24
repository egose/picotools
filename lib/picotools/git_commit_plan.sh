#!/usr/bin/env bash

if [ "${PICOTOOLS_GIT_COMMIT_PLAN_SH_LOADED:-0}" -eq 1 ]; then
  return 0
fi
PICOTOOLS_GIT_COMMIT_PLAN_SH_LOADED=1

# Contract: plan helpers accept raw JSON strings and caller-owned changed-file
# arrays/maps by nameref, print parsed values or validation diagnostics, and
# return nonzero for invalid model plans. Required globals: ALLOWED_TYPES and
# MAX_COMMIT_HEADER_LENGTH.

valid_commit_type() {
  local type="$1"
  local allowed_type

  for allowed_type in $ALLOWED_TYPES; do
    if [ "$type" = "$allowed_type" ]; then
      return 0
    fi
  done

  return 1
}

extract_commit_plan_json() {
  local raw="$1"
  local fenced

  if commit_plan_json_is_parseable "$raw"; then
    printf '%s\n' "$raw"
    return 0
  fi

  fenced=$(printf '%s\n' "$raw" | awk '
    BEGIN { in_fence = 0 }
    /^```[a-zA-Z0-9_-]*[[:space:]]*$/ {
      if (in_fence) { in_fence = 0; next }
      in_fence = 1
      next
    }
    in_fence { print }
  ' | awk '
    BEGIN { line_no = 0 }
    {
      if (line_no > 0) printf "\n"
      printf "%s", $0
      line_no++
    }
  ')
  if [ -n "$fenced" ] && commit_plan_json_is_parseable "$fenced"; then
    printf '%s\n' "$fenced"
    return 0
  fi

  printf '%s\n' "$raw"
}

commit_plan_json_is_parseable() {
  local plan_json="$1"

  printf '%s' "$plan_json" | jq -e 'type == "object" and (.commits | type == "array")' >/dev/null 2>&1
}

run_commit_plan_validation() {
  local plan_json="$1"
  local changed_files_ref_name="$2"
  local create_pr="$3"
  local scope="${4:-}"
  local error_output
  local status=0

  error_output=$(validate_commit_plan "$plan_json" "$changed_files_ref_name" "$scope" 2>&1 >/dev/null) || status=1
  if [ "$status" -eq 0 ]; then
    if [ "$create_pr" = 'true' ]; then
      error_output=$(validate_pull_request_plan "$plan_json" 2>&1 >/dev/null) || status=1
    else
      error_output=$(validate_optional_pull_request_plan "$plan_json" 2>&1 >/dev/null) || status=1
    fi
  fi

  printf '%s' "$error_output"
  return "$status"
}

validation_error() {
  printf 'Error: %s\n' "$1" >&2
  return 1
}

json_expr_is_true() {
  local json_text="$1"
  local jq_expression="$2"

  printf '%s' "$json_text" | jq -e "$jq_expression" >/dev/null 2>&1
}

json_required_nonempty_string() {
  local json_text="$1"
  local jq_expression="$2"
  local label="$3"

  if ! json_expr_is_true "$json_text" "${jq_expression} | type == \"string\" and length > 0"; then
    validation_error "$label must be a nonempty string"
    return 1
  fi
}

json_read_string() {
  local json_text="$1"
  local jq_expression="$2"

  printf '%s' "$json_text" | jq -r "$jq_expression" 2>/dev/null || true
}

json_read_type_or_null() {
  local json_text="$1"
  local jq_expression="$2"

  printf '%s' "$json_text" | jq -r "${jq_expression} | if . == null then \"null\" else type end" 2>/dev/null || true
}

valid_commit_message_style() {
  local message="$1"
  local first_word

  first_word=${message%% *}
  if [[ ! "$message" =~ ^[a-z][a-z0-9-]*([[:space:]].+)?$ ]]; then
    return 1
  fi

  # shellcheck disable=SC2221,SC2222
  case "$first_word" in
  *ed | *ing | is | are | was | were | been | being | has | have | had)
    return 1
    ;;
  esac

  return 0
}

plan_commit_count() {
  local plan_json="$1"

  printf '%s' "$plan_json" | jq -r '.commits | length'
}

build_changed_file_lookup_map() {
  local changed_files_ref_name="$1"
  local changed_file_set_ref_name="$2"
  local file
  local -n changed_files_ref="$changed_files_ref_name"
  # shellcheck disable=SC2178
  local -n changed_file_set_ref="$changed_file_set_ref_name"

  changed_file_set_ref=()
  for file in "${changed_files_ref[@]}"; do
    changed_file_set_ref["$file"]=1
  done
}

resolve_commit_files_into() {
  local plan_json="$1"
  local commit_index="$2"
  local changed_file_set_ref_name="$3"
  local files_var_name="$4"
  local file
  local -a requested_files=()
  # shellcheck disable=SC2178
  local -n changed_file_set_ref="$changed_file_set_ref_name"
  local -n files_ref="$files_var_name"

  mapfile -d '' -t requested_files < <(printf '%s' "$plan_json" | jq -rj ".commits[$commit_index].files[]? | . + \"\u0000\"")
  if [ "${#requested_files[@]}" -eq 0 ]; then
    echo "Error: commit plan item $((commit_index + 1)) must include files" >&2
    return 1
  fi

  files_ref=()
  for file in "${requested_files[@]}"; do
    if [ -z "${changed_file_set_ref[$file]:-}" ]; then
      echo "Error: commit plan referenced an unknown or ambiguous changed file: $file" >&2
      return 1
    fi

    files_ref+=("$file")
  done
}

validate_commit_plan_item_schema() {
  local plan_json="$1"
  local commit_index="$2"
  local scope="$3"
  local item_number=$((commit_index + 1))
  local item_type item_message file_count file_index header_length prefix_length
  local max_header_length=${MAX_COMMIT_HEADER_LENGTH:-100}

  if ! json_expr_is_true "$plan_json" ".commits[$commit_index] | type == \"object\""; then
    validation_error "commit plan item $item_number must be an object"
    return 1
  fi

  if ! json_required_nonempty_string "$plan_json" ".commits[$commit_index].type" "commit plan item $item_number type"; then
    return 1
  fi
  item_type=$(json_read_string "$plan_json" ".commits[$commit_index].type")
  if ! valid_commit_type "$item_type"; then
    validation_error "invalid commit type in plan: $item_type"
    return 1
  fi

  if ! json_required_nonempty_string "$plan_json" ".commits[$commit_index].message" "commit plan item $item_number message"; then
    return 1
  fi
  item_message=$(json_read_string "$plan_json" ".commits[$commit_index].message")
  if ! valid_commit_message_style "$item_message"; then
    validation_error "commit plan item $item_number must start with an imperative lower-case verb"
    return 1
  fi

  if [ -n "$scope" ]; then
    prefix_length=$((${#item_type} + ${#scope} + 4))
  else
    prefix_length=$((${#item_type} + 2))
  fi
  header_length=$((prefix_length + ${#item_message}))
  if [ "$header_length" -gt "$max_header_length" ]; then
    validation_error "commit plan item $item_number header must not exceed $max_header_length characters"
    return 1
  fi

  if ! json_expr_is_true "$plan_json" ".commits[$commit_index].files | type == \"array\" and length > 0"; then
    validation_error "commit plan item $item_number files must be a nonempty array"
    return 1
  fi

  file_count=$(printf '%s' "$plan_json" | jq -r ".commits[$commit_index].files | length")
  file_index=0
  while [ "$file_index" -lt "$file_count" ]; do
    if ! json_required_nonempty_string "$plan_json" ".commits[$commit_index].files[$file_index]" "commit plan item $item_number file $((file_index + 1))"; then
      return 1
    fi
    file_index=$((file_index + 1))
  done
}

validate_multi_commit_plan() {
  local plan_json="$1"
  local changed_files_ref_name="$2"
  local count commit_index file
  local -A changed_file_set=()
  local -A planned_file_set=()
  local -a commit_files=()

  build_changed_file_lookup_map "$changed_files_ref_name" changed_file_set

  count=$(plan_commit_count "$plan_json")
  commit_index=0
  while [ "$commit_index" -lt "$count" ]; do
    resolve_commit_files_into "$plan_json" "$commit_index" changed_file_set commit_files || return 1

    for file in "${commit_files[@]}"; do
      if [ -n "${planned_file_set[$file]:-}" ]; then
        echo "Error: commit plan assigned the same file to multiple commits: $file" >&2
        return 1
      fi
      planned_file_set[$file]=1
    done

    commit_index=$((commit_index + 1))
  done

  for file in "${!changed_file_set[@]}"; do
    if [ -z "${planned_file_set[$file]:-}" ]; then
      echo "Error: commit plan did not cover changed file: $file" >&2
      return 1
    fi
  done
}

validate_commit_plan() {
  local plan_json="$1"
  local changed_files_ref_name="$2"
  local scope="${3:-}"
  local count commit_index

  if ! json_expr_is_true "$plan_json" 'type == "object"'; then
    validation_error 'commit plan must be a JSON object'
    return 1
  fi

  if ! json_expr_is_true "$plan_json" 'has("commits") and (.commits | type == "array")'; then
    validation_error 'commit plan commits must be a nonempty array'
    return 1
  fi

  count=$(plan_commit_count "$plan_json")
  if [ "$count" -le 0 ]; then
    validation_error 'commit plan commits must be a nonempty array'
    return 1
  fi

  commit_index=0
  while [ "$commit_index" -lt "$count" ]; do
    validate_commit_plan_item_schema "$plan_json" "$commit_index" "$scope" || return 1
    commit_index=$((commit_index + 1))
  done

  validate_multi_commit_plan "$plan_json" "$changed_files_ref_name"
}

validate_pull_request_plan() {
  local plan_json="$1"
  local title body

  if ! json_expr_is_true "$plan_json" '.pull_request | type == "object"'; then
    validation_error 'pull_request must be an object when --pr is used'
    return 1
  fi

  if ! json_required_nonempty_string "$plan_json" '.pull_request.title' 'pull_request.title'; then
    return 1
  fi

  if ! json_required_nonempty_string "$plan_json" '.pull_request.body' 'pull_request.body'; then
    return 1
  fi

  title=$(json_read_string "$plan_json" '.pull_request.title')
  body=$(json_read_string "$plan_json" '.pull_request.body')
  if [ -z "$title" ] || [ -z "$body" ]; then
    validation_error 'pull_request.title and pull_request.body are required when --pr is used'
    return 1
  fi
}

validate_optional_pull_request_plan() {
  local plan_json="$1"

  if json_expr_is_true "$plan_json" 'has("pull_request") | not'; then
    return 0
  fi

  if json_expr_is_true "$plan_json" '.pull_request == null'; then
    return 0
  fi

  if ! json_expr_is_true "$plan_json" '.pull_request | type == "object"'; then
    validation_error 'pull_request must be an object when provided'
    return 1
  fi

  if json_expr_is_true "$plan_json" '.pull_request | has("title")'; then
    json_required_nonempty_string "$plan_json" '.pull_request.title' 'pull_request.title' || return 1
  fi

  if json_expr_is_true "$plan_json" '.pull_request | has("body")'; then
    json_required_nonempty_string "$plan_json" '.pull_request.body' 'pull_request.body' || return 1
  fi
}
