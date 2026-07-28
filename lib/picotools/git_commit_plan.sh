#!/usr/bin/env bash

if [ "${PICOTOOLS_GIT_COMMIT_PLAN_SH_LOADED:-0}" -eq 1 ]; then
  return 0
fi
PICOTOOLS_GIT_COMMIT_PLAN_SH_LOADED=1

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

  printf '%s' "$plan_json" | jq -e '.commits | type == "array"' >/dev/null 2>&1
}

run_commit_plan_validation() {
  local plan_json="$1"
  local changed_files="$2"
  local create_pr="$3"
  local error_output
  local status=0

  error_output=$(validate_commit_plan "$plan_json" "$changed_files" 2>&1 >/dev/null) || status=1
  if [ "$status" -eq 0 ] && [ "$create_pr" = 'true' ]; then
    error_output=$(validate_pull_request_plan "$plan_json" 2>&1 >/dev/null) || status=1
  fi

  printf '%s' "$error_output"
  return "$status"
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

resolve_changed_file_reference() {
  local requested_file="$1"
  local changed_files="$2"
  local normalized_requested_file candidate_file basename_match='' suffix_match=''
  local basename_count=0
  local suffix_count=0

  normalized_requested_file="${requested_file#:/}"
  normalized_requested_file="${normalized_requested_file#./}"

  while IFS= read -r candidate_file; do
    [ -n "$candidate_file" ] || continue

    if [ "$candidate_file" = "$normalized_requested_file" ]; then
      printf '%s\n' "$candidate_file"
      return 0
    fi

    if [ "${candidate_file##*/}" = "$normalized_requested_file" ]; then
      basename_match="$candidate_file"
      basename_count=$((basename_count + 1))
    fi

    case "$candidate_file" in
    "$normalized_requested_file" | */"$normalized_requested_file")
      suffix_match="$candidate_file"
      suffix_count=$((suffix_count + 1))
      ;;
    esac
  done <<<"$changed_files"

  if [ "$basename_count" -eq 1 ]; then
    printf '%s\n' "$basename_match"
    return 0
  fi

  if [ "$suffix_count" -eq 1 ]; then
    printf '%s\n' "$suffix_match"
    return 0
  fi

  return 1
}

resolve_commit_files_into() {
  local plan_json="$1"
  local commit_index="$2"
  local changed_files="$3"
  local files_var_name="$4"
  local file resolved_file
  local -a requested_files=()
  local -n files_ref="$files_var_name"

  mapfile -t requested_files < <(printf '%s' "$plan_json" | jq -r ".commits[$commit_index].files[]?")
  if [ "${#requested_files[@]}" -eq 0 ]; then
    echo "Error: commit plan item $((commit_index + 1)) must include files" >&2
    exit 1
  fi

  files_ref=()
  for file in "${requested_files[@]}"; do
    if ! resolved_file=$(resolve_changed_file_reference "$file" "$changed_files"); then
      echo "Error: commit plan referenced an unknown or ambiguous changed file: $file" >&2
      exit 1
    fi

    files_ref+=("$resolved_file")
  done
}

validate_multi_commit_plan() {
  local plan_json="$1"
  local changed_files="$2"
  local count commit_index file resolved_file
  local -A changed_file_set=()
  local -A planned_file_set=()
  local -a commit_files=()

  while IFS= read -r file; do
    if [ -n "$file" ]; then
      changed_file_set[$file]=1
    fi
  done <<<"$changed_files"

  count=$(plan_commit_count "$plan_json")
  commit_index=0
  while [ "$commit_index" -lt "$count" ]; do
    resolve_commit_files_into "$plan_json" "$commit_index" "$changed_files" commit_files

    for resolved_file in "${commit_files[@]}"; do
      if [ -z "${changed_file_set[$resolved_file]:-}" ]; then
        echo "Error: commit plan referenced an unknown changed file: $resolved_file" >&2
        exit 1
      fi
      if [ -n "${planned_file_set[$resolved_file]:-}" ]; then
        echo "Error: commit plan assigned the same file to multiple commits: $resolved_file" >&2
        exit 1
      fi
      planned_file_set[$resolved_file]=1
    done

    commit_index=$((commit_index + 1))
  done

  for file in "${!changed_file_set[@]}"; do
    if [ -z "${planned_file_set[$file]:-}" ]; then
      echo "Error: commit plan did not cover changed file: $file" >&2
      exit 1
    fi
  done
}

validate_commit_plan() {
  local plan_json="$1"
  local changed_files="$2"
  local count

  count=$(plan_commit_count "$plan_json")
  if [ "$count" -le 0 ]; then
    echo 'Error: commit plan must include at least one commit' >&2
    exit 1
  fi

  validate_multi_commit_plan "$plan_json" "$changed_files"
}

validate_pull_request_plan() {
  local plan_json="$1"
  local title_type body_type title body

  title_type=$(json_read_type_or_null "$plan_json" '.pull_request.title')
  if [ -n "$title_type" ] && [ "$title_type" != 'null' ] && [ "$title_type" != 'string' ]; then
    echo 'Error: pull_request.title must be a string when provided' >&2
    exit 1
  fi

  body_type=$(json_read_type_or_null "$plan_json" '.pull_request.body')
  if [ -n "$body_type" ] && [ "$body_type" != 'null' ] && [ "$body_type" != 'string' ]; then
    echo 'Error: pull_request.body must be a string when provided' >&2
    exit 1
  fi

  title=$(json_read_string "$plan_json" '.pull_request.title // empty')
  body=$(json_read_string "$plan_json" '.pull_request.body // empty')
  if [ -z "$title" ] || [ -z "$body" ]; then
    echo 'Error: pull_request.title and pull_request.body are required when --pr is used' >&2
    exit 1
  fi
}
