#!/usr/bin/env bash

if [ "${PICOTOOLS_GIT_COMMIT_EXECUTION_SH_LOADED:-0}" -eq 1 ]; then
  return 0
fi
PICOTOOLS_GIT_COMMIT_EXECUTION_SH_LOADED=1

# Contract: rendering functions print preview text only. Execution functions
# mutate Git state only through isolated temporary indexes and return nonzero on
# failures. Required dependencies: plan/workspace helpers, hook state helpers,
# debug_log, register_tmpfile, box helpers, PRE_COMMIT_CONFIG_FILE, and
# MAX_COMMIT_HEADER_LENGTH.
read_commit_plan_item() {
  local plan_json="$1"
  local commit_index="$2"
  local scope="$3"
  local changed_file_set_ref_name="$4"
  local type_ref_name="$5"
  local message_ref_name="$6"
  local title_ref_name="$7"
  local files_var_name="$8"
  local item_type item_message item_title
  local -n type_ref="$type_ref_name"
  local -n message_ref="$message_ref_name"
  local -n title_ref="$title_ref_name"

  item_type=$(printf '%s' "$plan_json" | jq -r ".commits[$commit_index].type // empty")
  item_message=$(printf '%s' "$plan_json" | jq -r ".commits[$commit_index].message // empty")

  if ! valid_commit_type "$item_type"; then
    echo "Error: invalid commit type in plan: $item_type" >&2
    return 1
  fi

  if [ -z "$item_message" ]; then
    echo "Error: commit plan item $((commit_index + 1)) is missing a message" >&2
    return 1
  fi

  if ! valid_commit_message_style "$item_message"; then
    echo "Error: commit plan item $((commit_index + 1)) must start with an imperative lower-case verb" >&2
    return 1
  fi

  item_title=$(format_commit_title "$item_type" "$scope" "$item_message")
  resolve_commit_files_into "$plan_json" "$commit_index" "$changed_file_set_ref_name" "$files_var_name" || return 1

  # shellcheck disable=SC2034
  {
    type_ref="$item_type"
    message_ref="$item_message"
    title_ref="$item_title"
  }
}

format_commit_title() {
  local type="$1"
  local scope="$2"
  local message="$3"
  local prefix available_chars

  if [ -n "$scope" ]; then
    prefix="${type}(${scope}): "
  else
    prefix="${type}: "
  fi

  available_chars=$((MAX_COMMIT_HEADER_LENGTH - ${#prefix}))
  if [ "$available_chars" -le 0 ]; then
    printf '%s\n' "${prefix:0:$MAX_COMMIT_HEADER_LENGTH}"
    return 0
  fi

  if [ "${#message}" -gt "$available_chars" ]; then
    if [ "$available_chars" -gt 3 ]; then
      message="${message:0:$((available_chars - 3))}..."
    else
      message="${message:0:$available_chars}"
    fi
  fi

  printf '%s%s\n' "$prefix" "$message"
}

pre_commit_config_exists_in_worktree() {
  [ -f "$(git_repo_root)/$PRE_COMMIT_CONFIG_FILE" ]
}

pre_commit_config_is_tracked() {
  git ls-files --error-unmatch -- "$PRE_COMMIT_CONFIG_FILE" >/dev/null 2>&1
}

pre_commit_config_commit_title() {
  local scope="$1"
  local action='update'

  if ! pre_commit_config_is_tracked; then
    action='add'
  fi

  format_commit_title chore "$scope" "$action pre-commit config"
}

should_separate_pre_commit_config_commit() {
  local plan_json="$1"
  local scope="$2"
  local changed_files_ref_name="$3"
  local type message title
  local -A changed_file_set=()
  local -a commit_files=()

  if ! changed_files_include_path "$changed_files_ref_name" "$PRE_COMMIT_CONFIG_FILE"; then
    return 1
  fi

  if ! pre_commit_config_exists_in_worktree; then
    return 1
  fi

  build_changed_file_lookup_map "$changed_files_ref_name" changed_file_set
  read_commit_plan_item "$plan_json" 0 "$scope" changed_file_set type message title commit_files || return 1
  if [ "${#commit_files[@]}" -eq 1 ] && [ "${commit_files[0]}" = "$PRE_COMMIT_CONFIG_FILE" ]; then
    return 1
  fi

  return 0
}

copy_commit_files() {
  local output_ref_name="$1"
  shift
  # shellcheck disable=SC2178
  local -n output_ref="$output_ref_name"

  output_ref=("$@")
}

copy_commit_files_without_pre_commit_config() {
  local output_ref_name="$1"
  shift
  local file
  # shellcheck disable=SC2178
  local -n output_ref="$output_ref_name"

  output_ref=()
  for file in "$@"; do
    if [ "$file" != "$PRE_COMMIT_CONFIG_FILE" ]; then
      output_ref+=("$file")
    fi
  done
}

effective_commit_count() {
  local plan_json="$1"
  local scope="$2"
  local changed_files_ref_name="$3"
  local count commit_index effective_count=0
  local separate_pre_commit_config=false
  local type message title
  local -A changed_file_set=()
  local -a commit_files=() effective_files=()

  build_changed_file_lookup_map "$changed_files_ref_name" changed_file_set
  if should_separate_pre_commit_config_commit "$plan_json" "$scope" "$changed_files_ref_name"; then
    separate_pre_commit_config=true
    effective_count=$((effective_count + 1))
  fi

  count=$(plan_commit_count "$plan_json")
  commit_index=0
  while [ "$commit_index" -lt "$count" ]; do
    read_commit_plan_item "$plan_json" "$commit_index" "$scope" changed_file_set type message title commit_files || return 1

    if [ "$separate_pre_commit_config" = 'true' ]; then
      copy_commit_files_without_pre_commit_config effective_files "${commit_files[@]}"
    else
      copy_commit_files effective_files "${commit_files[@]}"
    fi

    if [ "${#effective_files[@]}" -gt 0 ]; then
      effective_count=$((effective_count + 1))
    fi

    commit_index=$((commit_index + 1))
  done

  printf '%s\n' "$effective_count"
}

print_git_add_command() {
  if [ "$#" -eq 0 ]; then
    printf 'git add -A :/\n'
    return 0
  fi

  local pathspec
  local -a pathspecs=()

  git_literal_pathspecs_into pathspecs "$@"
  printf 'git add -A --'
  for pathspec in "${pathspecs[@]}"; do
    printf ' %q' "$pathspec"
  done
  printf '\n'
}

shell_squote() {
  local text="$1"

  printf "'%s'" "${text//\'/\'\\\'\'}"
}

print_git_commit_command() {
  local title="$1"

  printf 'git commit -m %s\n' "$(shell_squote "$title")"
}

print_commit_plan() {
  local plan_json="$1"
  local scope="$2"
  local changed_files_ref_name="$3"
  local count commit_index type message title width effective_count display_index=0
  local separate_pre_commit_config=false pre_commit_title
  # shellcheck disable=SC2034
  local -A changed_file_set=()
  local -a commit_files=() lines=()
  local -a effective_files=()

  build_changed_file_lookup_map "$changed_files_ref_name" changed_file_set
  count=$(plan_commit_count "$plan_json")
  effective_count=$(effective_commit_count "$plan_json" "$scope" "$changed_files_ref_name")

  lines+=("commit plan")
  if should_separate_pre_commit_config_commit "$plan_json" "$scope" "$changed_files_ref_name"; then
    separate_pre_commit_config=true
    pre_commit_title=$(pre_commit_config_commit_title "$scope")
    display_index=$((display_index + 1))
    if [ "$effective_count" -gt 1 ]; then
      lines+=("Commit ${display_index}:")
    fi
    lines+=("$(print_git_add_command "$PRE_COMMIT_CONFIG_FILE")")
    lines+=("$(print_git_commit_command "$pre_commit_title")")
    if [ "$display_index" -lt "$effective_count" ]; then
      lines+=("")
    fi
  fi

  commit_index=0
  while [ "$commit_index" -lt "$count" ]; do
    read_commit_plan_item "$plan_json" "$commit_index" "$scope" changed_file_set type message title commit_files || return 1

    if [ "$separate_pre_commit_config" = 'true' ]; then
      copy_commit_files_without_pre_commit_config effective_files "${commit_files[@]}"
    else
      copy_commit_files effective_files "${commit_files[@]}"
    fi

    if [ "${#effective_files[@]}" -eq 0 ]; then
      commit_index=$((commit_index + 1))
      continue
    fi

    display_index=$((display_index + 1))
    if [ "$effective_count" -eq 1 ]; then
      lines+=("$(print_git_add_command "${effective_files[@]}")")
    else
      lines+=("Commit ${display_index}:")
      lines+=("$(print_git_add_command "${effective_files[@]}")")
    fi

    lines+=("$(print_git_commit_command "$title")")
    if [ "$display_index" -lt "$effective_count" ]; then
      lines+=("")
    fi
    commit_index=$((commit_index + 1))
  done

  width=$(picotools_box_width_for_lines 60 "${lines[@]}")
  if [ "$width" -gt 120 ]; then
    width=120
  fi

  printf '\n'
  picotools_box_top "$width"
  picotools_box_line "${lines[0]}" "$width"
  picotools_box_separator "$width"

  for ((commit_index = 1; commit_index < ${#lines[@]}; commit_index++)); do
    picotools_box_wrap_line "${lines[$commit_index]}" "$width"
  done

  picotools_box_bottom "$width"
  printf '\n'
}

commit_files_match_intended() {
  local index_file="$1"
  local intended_files_ref_name="$2"
  local file
  local -a actual_files=()

  if git rev-parse --verify HEAD >/dev/null 2>&1; then
    while IFS= read -r -d '' file; do
      actual_files+=("$file")
    done < <(GIT_INDEX_FILE="$index_file" git diff --cached --name-only --no-renames -z HEAD --)
  else
    while IFS= read -r -d '' file; do
      actual_files+=("$file")
    done < <(GIT_INDEX_FILE="$index_file" git diff --cached --name-only --no-renames -z --)
  fi

  changed_file_arrays_match "$intended_files_ref_name" actual_files
}

create_isolated_commit() {
  local title="$1"
  local files_ref_name="$2"
  local repo_root index_file parent tree commit file
  local -a pathspecs=() commit_tree_args=()
  local -n files_ref="$files_ref_name"

  ensure_apply_index_empty || return 1

  repo_root=$(git_repo_root) || return 1
  index_file=$(mktemp) || return 1
  register_tmpfile "$index_file"
  rm -f "$index_file"
  if git rev-parse --verify HEAD >/dev/null 2>&1; then
    parent=$(git rev-parse HEAD)
    GIT_INDEX_FILE="$index_file" git read-tree HEAD
  else
    parent=''
  fi

  git_literal_pathspecs_into pathspecs "${files_ref[@]}"
  if ! GIT_INDEX_FILE="$index_file" git -C "$repo_root" add -A -- "${pathspecs[@]}"; then
    return 1
  fi
  if ! commit_files_match_intended "$index_file" "$files_ref_name"; then
    echo 'Error: isolated commit index does not match the planned file set.' >&2
    echo 'Recovery: real index was left empty; review git status --short and re-run git-commit.' >&2
    echo 'Planned commit paths:' >&2
    for file in "${files_ref[@]}"; do
      printf '  - %q\n' "$file" >&2
    done
    return 1
  fi

  if ! tree=$(GIT_INDEX_FILE="$index_file" git -C "$repo_root" write-tree); then
    return 1
  fi
  if [ -n "$parent" ]; then
    commit_tree_args_for_config commit_tree_args "$repo_root" "$tree" "$title" "$parent" || return 1
    if ! commit=$(git -C "$repo_root" commit-tree "${commit_tree_args[@]}"); then
      report_commit_tree_signing_hint commit_tree_args
      return 1
    fi
    if ! git -C "$repo_root" update-ref -m "git-commit: $title" HEAD "$commit" "$parent"; then
      return 1
    fi
  else
    commit_tree_args_for_config commit_tree_args "$repo_root" "$tree" "$title" || return 1
    if ! commit=$(git -C "$repo_root" commit-tree "${commit_tree_args[@]}"); then
      report_commit_tree_signing_hint commit_tree_args
      return 1
    fi
    if ! git -C "$repo_root" update-ref -m "git-commit: $title" HEAD "$commit"; then
      return 1
    fi
  fi
  git -C "$repo_root" reset -q --mixed HEAD --
}

report_commit_tree_signing_hint() {
  local args_ref_name="$1"
  local arg
  # shellcheck disable=SC2178
  local -n args_ref="$args_ref_name"

  for arg in "${args_ref[@]}"; do
    case "$arg" in
    -S | -S*)
      echo "Hint: commit.gpgSign is enabled. If pinentry failed, ensure GPG_TTY points to an interactive terminal, for example: export GPG_TTY=\$(tty)." >&2
      return 0
      ;;
    esac
  done
}

commit_tree_args_for_config() {
  local output_ref_name="$1"
  local repo_root="$2"
  local tree="$3"
  local title="$4"
  local parent="${5:-}"
  local signing_config status
  # shellcheck disable=SC2178
  local -n output_ref="$output_ref_name"

  output_ref=("$tree")
  if [ -n "$parent" ]; then
    output_ref+=(-p "$parent")
  fi
  output_ref+=(-m "$title")

  signing_config=$(git -C "$repo_root" config --bool --get commit.gpgSign 2>&1) || status=$?
  status=${status:-0}
  case "$status" in
  0)
    if [ "$signing_config" = 'true' ]; then
      output_ref+=(-S)
    fi
    ;;
  1)
    ;;
  *)
    printf '%s\n' "$signing_config" >&2
    return "$status"
    ;;
  esac
}

report_local_apply_failure() {
  local failed_commit_number="$1"
  local total_commits="$2"
  local completed_commits=$((failed_commit_number - 1))

  echo "Error: failed to create planned commit ${failed_commit_number}/${total_commits}." >&2
  if [ "$completed_commits" -eq 0 ]; then
    echo 'State: no planned commits were created; the real index is empty; selected changes remain in the worktree.' >&2
    echo 'Recovery: fix the reported error, then re-run git-commit --apply.' >&2
    return 0
  fi

  echo "State: HEAD contains the first ${completed_commits} planned commit(s); the real index is empty; remaining selected changes remain in the worktree." >&2
  echo 'Recovery: inspect git log --oneline and git status --short; either continue manually or reset only your local commits before re-running git-commit.' >&2
}

report_push_failure() {
  echo 'Error: push failed after local commits were created.' >&2
  echo 'State: local HEAD and worktree were left unchanged by git-commit after the failed push; remote state is whatever git push reported.' >&2
  echo 'Recovery: inspect git status --short, git log --oneline, and the remote branch before retrying git push or re-running git-commit.' >&2
}

report_pull_request_failure() {
  echo 'Error: pull request operation failed after local commits were pushed.' >&2
  echo 'State: local HEAD and the pushed remote branch were preserved; no local rollback was attempted.' >&2
  echo 'Recovery: inspect the remote branch and pull request state before retrying PR creation or update.' >&2
}

execute_commit_plan() {
  local plan_json="$1"
  local scope="$2"
  local changed_files_ref_name="$3"
  local count commit_index type message title pre_commit_title display_commit_number=0
  local separate_pre_commit_config=false effective_count
  # shellcheck disable=SC2034
  local -A changed_file_set=()
  local -a commit_files=()
  local -a effective_files=()

  build_changed_file_lookup_map "$changed_files_ref_name" changed_file_set
  count=$(plan_commit_count "$plan_json")
  effective_count=$(effective_commit_count "$plan_json" "$scope" "$changed_files_ref_name")
  debug_log "Applying commit plan with $effective_count commit(s)"

  if should_separate_pre_commit_config_commit "$plan_json" "$scope" "$changed_files_ref_name"; then
    separate_pre_commit_config=true
    pre_commit_title=$(pre_commit_config_commit_title "$scope")
    debug_log "Creating pre-commit config bootstrap commit: $pre_commit_title"
    copy_commit_files effective_files "$PRE_COMMIT_CONFIG_FILE"
    display_commit_number=$((display_commit_number + 1))
    if ! create_isolated_commit "$pre_commit_title" effective_files; then
      report_local_apply_failure "$display_commit_number" "$effective_count"
      return 1
    fi
  fi

  commit_index=0
  while [ "$commit_index" -lt "$count" ]; do
    read_commit_plan_item "$plan_json" "$commit_index" "$scope" changed_file_set type message title commit_files || return 1

    if [ "$separate_pre_commit_config" = 'true' ]; then
      copy_commit_files_without_pre_commit_config effective_files "${commit_files[@]}"
    else
      copy_commit_files effective_files "${commit_files[@]}"
    fi

    if [ "${#effective_files[@]}" -eq 0 ]; then
      commit_index=$((commit_index + 1))
      continue
    fi

    debug_log "Creating commit $((commit_index + 1))/$count: $title"
    display_commit_number=$((display_commit_number + 1))
    if ! create_isolated_commit "$title" effective_files; then
      report_local_apply_failure "$display_commit_number" "$effective_count"
      return 1
    fi
    commit_index=$((commit_index + 1))
  done
}
