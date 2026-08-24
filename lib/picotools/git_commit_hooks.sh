#!/usr/bin/env bash

if [ "${PICOTOOLS_GIT_COMMIT_HOOKS_SH_LOADED:-0}" -eq 1 ]; then
  return 0
fi
PICOTOOLS_GIT_COMMIT_HOOKS_SH_LOADED=1

# Contract: hook/state helpers accept array namerefs for file sets, return
# nonzero to their caller on all policy failures, and write actionable recovery
# diagnostics to stderr. Required callbacks/globals: debug_log, register_tmpfile,
# cleanup_tmpfiles, PRE_COMMIT_CONFIG_FILE, and workspace path/diff helpers.
ensure_changes_exist() {
  local status

  status=$(git status --porcelain)
  if [ -z "$status" ]; then
    echo 'Error: no file changes found in the current git workspace' >&2
    return 1
  fi
}

ensure_no_staged_changes() {
  local staged_status unstage_changes

  staged_status=$(git diff --cached --name-only)
  if [ -n "$staged_status" ]; then
    unstage_changes=$(picotools_prompt_yes_no 'Staged changes detected. Unstage them with git restore --staged :/?' no)
    if [ "$unstage_changes" = 'yes' ]; then
      git restore --staged :/
      return 0
    fi

    echo 'Error: git-commit requires no pre-staged changes. Unstage them first.' >&2
    return 1
  fi
}

ensure_apply_index_empty() {
  local staged_status

  if git diff --cached --quiet --; then
    return 0
  fi

  staged_status=$(git diff --cached --name-only)
  echo 'Error: real Git index changed after git-commit planning started.' >&2
  echo 'git-commit applies plans only from an empty index so unplanned staged files cannot be committed.' >&2
  if [ -n "$staged_status" ]; then
    echo 'Staged paths:' >&2
    printf '%s\n' "$staged_status" >&2
  fi
  echo 'Recovery: unstage unrelated paths with git restore --staged <path> or commit them separately, then re-run git-commit.' >&2
  return 1
}

changed_file_arrays_match() {
  local expected_ref_name="$1"
  local actual_ref_name="$2"
  local file
  local -A expected_set=()
  local -n expected_ref="$expected_ref_name"
  local -n actual_ref="$actual_ref_name"

  if [ "${#expected_ref[@]}" -ne "${#actual_ref[@]}" ]; then
    return 1
  fi

  for file in "${expected_ref[@]}"; do
    expected_set["$file"]=$((${expected_set["$file"]:-0} + 1))
  done

  for file in "${actual_ref[@]}"; do
    if [ -z "${expected_set[$file]:-}" ]; then
      return 1
    fi
    expected_set["$file"]=$((expected_set["$file"] - 1))
    if [ "${expected_set[$file]}" -lt 0 ]; then
      return 1
    fi
  done

  return 0
}

print_path_list_for_error() {
  local file

  for file in "$@"; do
    printf '  - %q\n' "$file" >&2
  done
}

capture_workspace_fingerprint() {
  local output_ref_name="$1"
  local changed_files_ref_name="$2"
  local repo_root temp_file file has_head=false fingerprint
  local -a pathspecs=()
  local -n changed_files_ref="$changed_files_ref_name"
  local -n output_ref="$output_ref_name"

  repo_root=$(git_repo_root) || return 1
  temp_file=$(mktemp) || return 1
  register_tmpfile "$temp_file"
  git_literal_pathspecs_into pathspecs "${changed_files_ref[@]}"
  if git rev-parse --verify HEAD >/dev/null 2>&1; then
    has_head=true
  fi

  {
    printf 'head\0'
    if [ "$has_head" = true ]; then
      git rev-parse HEAD
    else
      printf '<unborn>\n'
    fi
    printf '\0paths\0'
    for file in "${changed_files_ref[@]}"; do
      printf '%s\0' "$file"
    done
    printf 'diff\0'
    if [ "${#pathspecs[@]}" -gt 0 ]; then
      if [ "$has_head" = true ]; then
        git -C "$repo_root" diff --no-ext-diff --binary HEAD -- "${pathspecs[@]}"
      else
        git -C "$repo_root" diff --no-ext-diff --binary --cached -- "${pathspecs[@]}"
      fi
    fi
    printf '\0worktree-blobs\0'
    for file in "${changed_files_ref[@]}"; do
      printf '%s\0' "$file"
      if [ -e "$repo_root/$file" ] || [ -L "$repo_root/$file" ]; then
        git -C "$repo_root" hash-object --no-filters -- "$file"
      else
        printf '<missing>\n'
      fi
      printf '\0'
    done
  } >"$temp_file"

  fingerprint=$(git -C "$repo_root" hash-object "$temp_file") || return 1
  printf -v output_ref '%s' "$fingerprint"
}

revalidate_workspace_before_apply() {
  local planned_changed_files_ref_name="$1"
  local planned_fingerprint="$2"
  local current_dir="$3"
  shift 3
  local repo_root selected_path current_fingerprint resolved_path
  # shellcheck disable=SC2034
  local -a selected_paths=() all_current_files=() current_changed_files=()
  local -n planned_changed_files_ref="$planned_changed_files_ref_name"

  ensure_apply_index_empty || return 1

  repo_root=$(git_repo_root) || return 1
  for selected_path in "$@"; do
    resolved_path=$(resolve_scope_path "$repo_root" "$current_dir" "$selected_path") || return 1
    selected_paths+=("$resolved_path")
  done
  collect_changed_files_into all_current_files
  filter_changed_files_to_scope_into current_changed_files all_current_files "${selected_paths[@]}"
  if ! changed_file_arrays_match "$planned_changed_files_ref_name" current_changed_files; then
    echo 'Error: stale commit plan: selected changed paths no longer match the approved plan.' >&2
    echo 'Recovery: review git status --short, then re-run git-commit so the model sees the current path set.' >&2
    echo 'Planned paths:' >&2
    print_path_list_for_error "${planned_changed_files_ref[@]}"
    echo 'Current selected paths:' >&2
    print_path_list_for_error "${current_changed_files[@]}"
    return 1
  fi

  capture_workspace_fingerprint current_fingerprint current_changed_files
  if [ "$current_fingerprint" != "$planned_fingerprint" ]; then
    echo 'Error: stale commit plan: selected file contents changed after the plan was generated.' >&2
    echo 'Recovery: review git diff, then re-run git-commit so the model sees the current content.' >&2
    return 1
  fi
}

pre_commit_hook_path() {
  local repo_root hook_path

  repo_root=$(git_repo_root) || return 1
  hook_path=$(git -C "$repo_root" rev-parse --git-path hooks/pre-commit) || return 1
  if [[ "$hook_path" != /* ]]; then
    hook_path="$repo_root/$hook_path"
  fi
  printf '%s\n' "$hook_path"
}

git_index_path() {
  git rev-parse --git-path index
}

split_index_enabled() {
  [ "$(git config --bool core.splitIndex 2>/dev/null || true)" = 'true' ]
}

initialize_temporary_index() {
  local index_file="$1"

  rm -f "$index_file"
  if git rev-parse --verify HEAD >/dev/null 2>&1; then
    GIT_INDEX_FILE="$index_file" git read-tree HEAD
    return $?
  fi

  GIT_INDEX_FILE="$index_file" git read-tree --empty
}

filter_outside_changed_files_into() {
  local output_ref_name="$1"
  local all_files_ref_name="$2"
  local selected_files_ref_name="$3"
  local file
  local -A selected_set=()
  # shellcheck disable=SC2178
  local -n output_ref="$output_ref_name"
  local -n all_files_ref="$all_files_ref_name"
  local -n selected_files_ref="$selected_files_ref_name"

  output_ref=()
  for file in "${selected_files_ref[@]}"; do
    selected_set["$file"]=1
  done

  for file in "${all_files_ref[@]}"; do
    if [ -z "${selected_set[$file]:-}" ]; then
      output_ref+=("$file")
    fi
  done
}

reject_out_of_scope_hook_mutations() {
  local before_files_ref_name="$1"
  local before_fingerprint="$2"
  local selected_files_ref_name="$3"
  local current_fingerprint
  # shellcheck disable=SC2034
  local -a all_after_files=() after_files=()
  local -n before_files_ref="$before_files_ref_name"

  collect_changed_files_into all_after_files
  filter_outside_changed_files_into after_files all_after_files "$selected_files_ref_name"
  if ! changed_file_arrays_match "$before_files_ref_name" after_files; then
    echo 'Error: preliminary pre-commit hook changed files outside the selected scope.' >&2
    echo 'Recovery: review git status --short, keep hook modifications inside selected paths, then re-run git-commit --apply.' >&2
    echo 'Out-of-scope paths before hook:' >&2
    print_path_list_for_error "${before_files_ref[@]}"
    echo 'Out-of-scope paths after hook:' >&2
    print_path_list_for_error "${after_files[@]}"
    return 1
  fi

  capture_workspace_fingerprint current_fingerprint after_files
  if [ "$current_fingerprint" != "$before_fingerprint" ]; then
    echo 'Error: preliminary pre-commit hook modified files outside the selected scope.' >&2
    echo 'Recovery: review git status --short, keep hook modifications inside selected paths, then re-run git-commit --apply.' >&2
    return 1
  fi
}

run_pre_commit_checks() {
  local changed_files_ref_name="$1"
  local retry_count="$2"
  local hook_path temp_index repo_root before_outside_fingerprint attempt=1 hook_status
  local max_attempts=$((retry_count + 1))
  local -n changed_files_ref="$changed_files_ref_name"
  # shellcheck disable=SC2034
  local -a all_before_files=() before_outside_files=()
  local -a pathspecs=()

  hook_path=$(pre_commit_hook_path) || return 1
  if [ ! -x "$hook_path" ]; then
    debug_log 'Skipping pre-commit checks because no executable hook was found'
    return 0
  fi

  if split_index_enabled; then
    echo 'Error: preliminary pre-commit checks do not support split-index repositories.' >&2
    echo 'Recovery: disable core.splitIndex before running git-commit --apply, or run hook checks manually.' >&2
    return 1
  fi

  temp_index=$(mktemp) || return 1
  register_tmpfile "$temp_index"
  trap 'cleanup_tmpfiles' EXIT

  repo_root=$(git_repo_root) || return 1
  collect_changed_files_into all_before_files
  filter_outside_changed_files_into before_outside_files all_before_files changed_files_ref
  capture_workspace_fingerprint before_outside_fingerprint before_outside_files

  debug_log "Running pre-commit hook for ${#changed_files_ref[@]} changed file(s)"
  echo 'Pre-commit checks:'
  while true; do
    if [ "$max_attempts" -gt 1 ]; then
      printf 'Attempt %d/%d\n' "$attempt" "$max_attempts"
    fi

    initialize_temporary_index "$temp_index"
    git_literal_pathspecs_into pathspecs "${changed_files_ref[@]}"
    GIT_INDEX_FILE="$temp_index" git -C "$repo_root" add -A -- "${pathspecs[@]}"

    hook_status=0
    (cd "$repo_root" && GIT_INDEX_FILE="$temp_index" "$hook_path") || hook_status=$?
    if ! reject_out_of_scope_hook_mutations before_outside_files "$before_outside_fingerprint" "$changed_files_ref_name"; then
      return 1
    fi

    if [ "$hook_status" -eq 0 ]; then
      printf '\n'
      return 0
    fi

    printf '\n'

    if [ "$attempt" -ge "$max_attempts" ]; then
      echo "Error: pre-commit checks failed after $max_attempts attempts" >&2
      return 1
    fi

    attempt=$((attempt + 1))
  done
}

prepare_workspace_changes() {
  local output_ref_name="$1"
  local pre_commit_retries="$2"
  local current_dir="$3"
  local run_preliminary_hooks="$4"
  shift 4
  local changed_file_count repo_root selected_path resolved_path
  # shellcheck disable=SC2034
  local -a selected_paths=() prepared_changed_files=() filtered_changed_files=()
  # shellcheck disable=SC2178
  local -n output_ref="$output_ref_name"

  debug_log 'Checking repository state'
  require_git_repository || return 1
  ensure_no_staged_changes || return 1
  ensure_changes_exist || return 1

  debug_log 'Collecting changed files'
  collect_changed_files_into prepared_changed_files
  repo_root=$(git_repo_root) || return 1
  for selected_path in "$@"; do
    resolved_path=$(resolve_scope_path "$repo_root" "$current_dir" "$selected_path") || return 1
    selected_paths+=("$resolved_path")
  done
  filter_changed_files_to_scope_into filtered_changed_files prepared_changed_files "${selected_paths[@]}"
  if [ "${#selected_paths[@]}" -gt 0 ]; then
    debug_log "Filtering changed files to ${#selected_paths[@]} selected path(s)"
  fi
  changed_file_count=${#filtered_changed_files[@]}
  if [ "$changed_file_count" -eq 0 ]; then
    if [ "${#selected_paths[@]}" -gt 0 ]; then
      echo 'Error: no file changes found in the selected --path scope' >&2
    else
      echo 'Error: no file changes found in the current git workspace' >&2
    fi
    return 1
  fi
  debug_log "Collected $changed_file_count changed file(s)"

  if [ "$run_preliminary_hooks" = 'true' ]; then
    run_pre_commit_checks filtered_changed_files "$pre_commit_retries" || return 1
    ensure_changes_exist || return 1

    debug_log 'Refreshing changed files after pre-commit checks'
    collect_changed_files_into prepared_changed_files
    filter_changed_files_to_scope_into filtered_changed_files prepared_changed_files "${selected_paths[@]}"
    changed_file_count=${#filtered_changed_files[@]}
    if [ "$changed_file_count" -eq 0 ]; then
      echo 'Error: no file changes remained in the selected --path scope after pre-commit checks' >&2
      return 1
    fi
    debug_log "Collected $changed_file_count changed file(s) after pre-commit"
  else
    debug_log 'Skipping repository pre-commit hook checks in preview mode'
  fi

  # shellcheck disable=SC2034
  # shellcheck disable=SC2178
  output_ref=("${filtered_changed_files[@]}")
}
