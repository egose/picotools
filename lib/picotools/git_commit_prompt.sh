#!/usr/bin/env bash

if [ "${PICOTOOLS_GIT_COMMIT_PROMPT_SH_LOADED:-0}" -eq 1 ]; then
  return 0
fi
PICOTOOLS_GIT_COMMIT_PROMPT_SH_LOADED=1

# Contract: prompt helpers print generated prompt text to stdout. The request
# helper writes a validated plan JSON into an output nameref and returns nonzero
# on model or validation failures. Required callbacks/globals: debug_log,
# MAX_COMMIT_PLAN_* limits, request_commit_plan, record_raw_commit_plan_response,
# debug_commit_plan_response_diagnostic, workspace JSON/diff helpers, and plan
# validation helpers.
count_nonempty_lines() {
  local text="$1"
  local count=0 line

  while IFS= read -r line; do
    if [ -n "$line" ]; then
      count=$((count + 1))
    fi
  done <<<"$text"

  printf '%s\n' "$count"
}

commit_planning_response_shape() {
  local include_pr_details="${1:-false}"

  if [ "$include_pr_details" = 'true' ]; then
    printf '%s\n' '{"commits":[{"type":"feat","message":"short summary","files":["path/to/file"]}],"pull_request":{"title":"short pr title","body":"detailed markdown description"}}'
    return 0
  fi

  printf '%s\n' '{"commits":[{"type":"feat","message":"short summary","files":["path/to/file"]}]}'
}

commit_planning_pull_request_rules() {
  cat <<'EOF'
Pull request rules:
- `pull_request.title` must be concise and descriptive for the full change set.
- `pull_request.body` must be a detailed pull request description for the full change set.
- Keep the pull request title and body consistent with the planned commits.
EOF
}

commit_planning_rules() {
  cat <<'EOF'
Rules:
- Allowed types: feat, fix, docs, refactor, chore, perf, test, ci
- The message must be the commit subject suffix only. Do not include the type or scope prefix.
- The message must start with an imperative lower-case verb.
- Describe only the current changed files and diff. Do not reuse unrelated prior context, example text, placeholders, or pull request content unless it is provided in this prompt.
- The final commit header, including the type/scope prefix, must not exceed 100 characters.
- When a scope is provided, do not repeat that scope value or its parent package/org prefix in the message unless it is required for clarity.
- Prefer one commit unless the changes clearly belong to distinct tasks.
- Prefer separate commits when reusable supporting changes are independently useful from the consuming feature.
- When one tool or shared capability is extended to support a new tool, prefer one commit for the supporting capability and another for the new consuming feature when the split is coherent.
- Each changed file must appear in exactly one commit, even when there is only one commit.
- Before returning, check the full changed-file list and confirm every listed file appears exactly once across all commit `files` arrays.
- Before returning, confirm no file path appears in more than one commit.
- Before returning, build the union of every commit `files` array and compare it against the changed-file list. If any file is duplicated, missing, unknown, or ambiguous, rewrite the plan before returning.
- Use file paths exactly as provided.
- Do not include markdown fences or commentary.
- Before returning, confirm the final response string is a single valid JSON object with the exact requested shape and no extra text before or after it.
EOF
}

commit_planning_system_message() {
  local include_pr_details="${1:-false}"

  cat <<'EOF'
You are an expert software engineer creating conventional commit plans.
EOF

  printf '\nReturn JSON only with this exact shape:\n%s\n' "$(commit_planning_response_shape "$include_pr_details")"
  if [ "$include_pr_details" = 'true' ]; then
    printf '\n%s\n' "$(commit_planning_pull_request_rules)"
  fi
  printf '\n%s\n' "$(commit_planning_rules)"
}

build_pull_request_context_block() {
  local pr_base_branch="$1"
  local existing_pr_title="$2"
  local existing_pr_body="$3"
  local existing_pr_exists="$4"
  local existing_pr_body_section

  printf '\nPull request base branch:\n%s\n' "$pr_base_branch"

  if [ "$existing_pr_exists" = 'true' ]; then
    # shellcheck disable=SC2016
    printf '\nExisting open pull request:\nYes\n\nGenerate `pull_request.title` and `pull_request.body` for the full pull request after the current local changes are pushed. Preserve and extend relevant details from the existing pull request content below so the result covers both the existing PR changes and the current local changes.\n\nExisting pull request title:\n%s\n' "${existing_pr_title:-'(none)'}"
    existing_pr_body_section=$(truncate_commit_plan_section 'existing pull request body' "$existing_pr_body" "$MAX_COMMIT_PLAN_EXISTING_PR_BODY_CHARS")
    printf '\nExisting pull request body:\n%s\n' "$existing_pr_body_section"
    return 0
  fi

  # shellcheck disable=SC2016
  printf '\nExisting open pull request:\nNo\n\nGenerate `pull_request.title` and `pull_request.body` for the pull request that should be created from these current local changes.\n'
}

build_commit_planning_message() {
  local branch="$1"
  local scope="$2"
  local changed_files_json="$3"
  local diff_output="$4"
  local create_pr="${5:-false}"
  local pr_base_branch="${6:-}"
  local existing_pr_title="${7:-}"
  local existing_pr_body="${8:-}"
  local existing_pr_exists="${9:-false}"
  local changed_files_section diff_section pr_section=''

  if [ -z "$scope" ]; then
    scope='(none)'
  fi

  changed_files_section=$(truncate_commit_plan_section 'changed file list' "$changed_files_json" "$MAX_COMMIT_PLAN_CHANGED_FILES_CHARS")
  diff_section=$(truncate_commit_plan_section 'diff' "$diff_output" "$MAX_COMMIT_PLAN_DIFF_CHARS")

  if [ "$create_pr" = 'true' ]; then
    pr_section=$(build_pull_request_context_block "$pr_base_branch" "$existing_pr_title" "$existing_pr_body" "$existing_pr_exists")
  fi

  printf '%s\n\n%s\n%s\n\n%s\n%s\n\n%s\n%s\n\n%s\n%s%s\n' \
    'Analyze these current git workspace changes and propose conventional commit plan JSON.' \
    'Current branch:' "$branch" \
    'Derived scope:' "$scope" \
    'Changed files JSON array (use exact repository-relative strings from this array):' "$changed_files_section" \
    'Unified diff:' "$diff_section" \
    "$pr_section"
}

build_commit_planning_retry_message() {
  local original_user_message="$1"
  local correction="$2"
  local normalized_correction

  case "$correction" in
  'Error: commit plan assigned the same file to multiple commits:'*)
    normalized_correction="${correction} Remove duplicate file assignments. Each changed file must appear in exactly one commit, and no file may appear in more than one commit. Compare every file path across all commits before returning."
    ;;
  'Error: commit plan did not cover changed file:'*)
    normalized_correction="${correction} Include every changed file exactly once across the commit plan before returning."
    ;;
  'Error: commit plan referenced an unknown or ambiguous changed file:'* | 'Error: commit plan referenced an unknown changed file:'*)
    normalized_correction="${correction} Use only file paths from the provided changed-file list and keep each path assigned exactly once."
    ;;
  *)
    normalized_correction="$correction"
    ;;
  esac

  printf '%s\n\n%s\n%s\n\n%s\n' \
    'A previous attempt produced an invalid commit plan. Reuse the same workspace information below.' \
    'Correction required:' "${normalized_correction} Re-check the changed-file list and your final response string before returning." \
    "$original_user_message"
}

request_validated_commit_plan() {
  local output_ref_name="$1"
  local profile="$2"
  local model="$3"
  local additional_profile="$4"
  local additional_model="$5"
  local branch="$6"
  local scope="$7"
  local changed_files_ref_name="$8"
  local diff_output="$9"
  local create_pr="${10}"
  local resolved_pr_base_branch="${11:-}"
  local existing_pr_title="${12:-}"
  local existing_pr_body="${13:-}"
  local existing_pr_exists="${14:-false}"
  local system_message user_message raw_requested_plan_json requested_plan_json retry_message attempt max_attempts validation_error changed_files_json
  # shellcheck disable=SC2178
  local -n output_ref="$output_ref_name"

  debug_log 'Collecting workspace diff for commit planning'
  changed_files_json=$(changed_files_json_array "$changed_files_ref_name")
  system_message=$(commit_planning_system_message "$create_pr")
  user_message=$(build_commit_planning_message "$branch" "$scope" "$changed_files_json" "$diff_output" "$create_pr" "$resolved_pr_base_branch" "$existing_pr_title" "$existing_pr_body" "$existing_pr_exists")

  max_attempts=2
  attempt=1
  validation_error=''
  while true; do
    debug_log "Requesting commit plan, attempt $attempt/$max_attempts"
    if [ "$attempt" -eq 1 ]; then
      raw_requested_plan_json=$(request_commit_plan "$profile" "$model" "$additional_profile" "$additional_model" "$system_message" "$user_message") || return $?
    else
      retry_message=$(build_commit_planning_retry_message "$user_message" "$validation_error")
      debug_log 'Retrying commit plan request with correction guidance'
      raw_requested_plan_json=$(request_commit_plan "$profile" "$model" "$additional_profile" "$additional_model" "$system_message" "$retry_message") || return $?
    fi

    record_raw_commit_plan_response "$raw_requested_plan_json"
    requested_plan_json=$(extract_commit_plan_json "$raw_requested_plan_json")
    debug_log "Extracted commit plan JSON (${#requested_plan_json} chars)"

    if commit_plan_json_is_parseable "$requested_plan_json"; then
      validation_error=$(run_commit_plan_validation "$requested_plan_json" "$changed_files_ref_name" "$create_pr" "$scope") && {
        debug_log 'Validated commit plan JSON'
        # shellcheck disable=SC2034,SC2178
        output_ref="$requested_plan_json"
        return 0
      }
    else
      validation_error='Your previous response did not contain parseable commit plan JSON. Return ONLY the JSON object with the exact shape requested, no markdown fences, no commentary, no prose before or after the JSON.'
    fi

    if [ "$attempt" -ge "$max_attempts" ]; then
      debug_log "Commit plan validation failed after $max_attempts attempts"
      break
    fi

    attempt=$((attempt + 1))
  done

  if [ -n "$validation_error" ]; then
    case "$validation_error" in
    'Error: '*)
      printf '%s\n' "$validation_error" >&2
      ;;
    *)
      printf 'Error: %s\n' "$validation_error" >&2
      ;;
    esac
  fi

  debug_commit_plan_response_diagnostic "$raw_requested_plan_json"

  case "$validation_error" in
  'Error: '*)
    return 1
    ;;
  esac

  echo 'Error: model-profile ask did not return valid commit plan JSON' >&2
  return 1
}
