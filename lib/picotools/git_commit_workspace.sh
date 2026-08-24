#!/usr/bin/env bash

if [ "${PICOTOOLS_GIT_COMMIT_WORKSPACE_SH_LOADED:-0}" -eq 1 ]; then
  return 0
fi
PICOTOOLS_GIT_COMMIT_WORKSPACE_SH_LOADED=1

# Contract: workspace helpers take scalar paths or caller-owned array namerefs,
# emit requested values to stdout, and return nonzero with stderr diagnostics on
# invalid paths or Git failures. Required callback/globals for prompt diff
# helpers: debug_log and MAX_COMMIT_PLAN_* limits.

git_repo_root() {
  git rev-parse --show-toplevel
}

git_literal_pathspec() {
  local repo_relative_path="$1"

  printf ':(top,literal)%s\n' "$repo_relative_path"
}

git_literal_pathspecs_into() {
  local output_ref_name="$1"
  shift
  local file
  # shellcheck disable=SC2178
  local -n output_ref="$output_ref_name"

  output_ref=()
  for file in "$@"; do
    output_ref+=("$(git_literal_pathspec "$file")")
  done
}

resolve_scope_path() {
  local repo_root="$1"
  local current_dir="$2"
  local raw_path="$3"
  local absolute_path parent_dir leaf_name

  raw_path="${raw_path#:/}"
  if [ -z "$raw_path" ]; then
    echo 'Error: --path requires a non-empty file or directory path' >&2
    return 1
  fi

  if [[ "$raw_path" = /* ]]; then
    absolute_path="$raw_path"
  else
    absolute_path="$current_dir/$raw_path"
  fi

  absolute_path="${absolute_path%/}"
  parent_dir=$(dirname "$absolute_path")
  leaf_name=$(basename "$absolute_path")
  parent_dir=$(cd "$parent_dir" 2>/dev/null && pwd -P) || {
    echo "Error: unable to resolve --path '$raw_path'" >&2
    return 1
  }

  if [ "$leaf_name" = '.' ]; then
    absolute_path="$parent_dir"
  else
    absolute_path="$parent_dir/$leaf_name"
  fi

  case "$absolute_path" in
  "$repo_root")
    printf '.\n'
    ;;
  "$repo_root"/*)
    printf '%s\n' "${absolute_path#"$repo_root"/}"
    ;;
  *)
    echo "Error: --path must stay inside the repository: $raw_path" >&2
    return 1
    ;;
  esac
}

filter_changed_files_to_scope_into() {
  local output_ref_name="$1"
  local changed_files_ref_name="$2"
  shift 2
  local file selected_path
  local -a selected_paths=("$@")
  # shellcheck disable=SC2178
  local -n output_ref="$output_ref_name"
  local -n changed_files_ref="$changed_files_ref_name"

  output_ref=()

  if [ "${#selected_paths[@]}" -eq 0 ]; then
    output_ref=("${changed_files_ref[@]}")
    return 0
  fi

  for file in "${changed_files_ref[@]}"; do
    for selected_path in "${selected_paths[@]}"; do
      if [ "$selected_path" = '.' ]; then
        output_ref+=("$file")
        break
      fi

      case "$file" in
      "$selected_path" | "$selected_path"/*)
        output_ref+=("$file")
        break
        ;;
      esac
    done
  done
}

load_scope_paths_file() {
  local file_path="$1"
  local output_ref_name="$2"
  local line
  # shellcheck disable=SC2178
  local -n output_ref="$output_ref_name"

  output_ref=()

  if [ ! -f "$file_path" ]; then
    echo "Error: --path-file not found: $file_path" >&2
    return 1
  fi

  while IFS= read -r line || [ -n "$line" ]; do
    if [ -n "$line" ]; then
      output_ref+=("$line")
    fi
  done <"$file_path"
}

collect_changed_files_into() {
  local output_ref_name="$1"
  local repo_root file
  local has_head=false
  local -A seen=()
  # shellcheck disable=SC2178
  local -n output_ref="$output_ref_name"

  output_ref=()

  repo_root=$(git_repo_root)

  if git rev-parse --verify HEAD >/dev/null 2>&1; then
    has_head=true
  fi

  if [ "$has_head" = true ]; then
    while IFS= read -r -d '' file; do
      if [ -z "${seen[$file]:-}" ]; then
        seen[$file]=1
        output_ref+=("$file")
      fi
    done < <(git -C "$repo_root" diff --name-only -z HEAD --)
  else
    while IFS= read -r -d '' file; do
      if [ -z "${seen[$file]:-}" ]; then
        seen[$file]=1
        output_ref+=("$file")
      fi
    done < <(git -C "$repo_root" diff --name-only -z --cached --)
  fi

  while IFS= read -r -d '' file; do
    if [ -z "${seen[$file]:-}" ]; then
      seen[$file]=1
      output_ref+=("$file")
    fi
  done < <(git -C "$repo_root" ls-files -z --others --exclude-standard)
}

collect_changed_files() {
  local -a files=()

  collect_changed_files_into files
  printf '%s\n' "${files[@]}"
}

changed_files_include_path() {
  local changed_files_ref_name="$1"
  local target_path="$2"
  local file
  local -n changed_files_ref="$changed_files_ref_name"

  for file in "${changed_files_ref[@]}"; do
    if [ "$file" = "$target_path" ]; then
      return 0
    fi
  done

  return 1
}

changed_files_json_array() {
  local changed_files_ref_name="$1"
  local file separator=''
  local -n changed_files_ref="$changed_files_ref_name"

  printf '['
  for file in "${changed_files_ref[@]}"; do
    printf '%s' "$separator"
    json_escape_string "$file"
    separator=','
  done
  printf ']\n'
}

json_escape_string() {
  local text="$1"
  local char escaped=''
  local index

  for ((index = 0; index < ${#text}; index++)); do
    char="${text:index:1}"
    case "$char" in
    '"')
      escaped+='\"'
      ;;
    \\)
      escaped+="\\\\"
      ;;
    $'\n')
      escaped+='\n'
      ;;
    $'\t')
      escaped+='\t'
      ;;
    $'\r')
      escaped+='\r'
      ;;
    $'\b')
      escaped+='\b'
      ;;
    $'\f')
      escaped+='\f'
      ;;
    *)
      escaped+="$char"
      ;;
    esac
  done

  printf '"%s"' "$escaped"
}

file_size_bytes() {
  local file_path="$1"

  wc -c <"$file_path" | tr -d '[:space:]'
}

added_file_diff_for_prompt() {
  local repo_root="$1"
  local file="$2"
  local file_path file_size

  file_path="$repo_root/$file"
  file_size=$(file_size_bytes "$file_path")
  if [ "$file_size" -gt "$MAX_COMMIT_PLAN_ADDED_FILE_BYTES" ]; then
    debug_log "Omitting added file diff for '$file' because ${file_size} bytes exceeds ${MAX_COMMIT_PLAN_ADDED_FILE_BYTES}"
    printf '[Omitted added file diff for %s because its size (%s bytes) exceeds the prompt limit for added files (%s bytes).]\n' \
      "$file" "$file_size" "$MAX_COMMIT_PLAN_ADDED_FILE_BYTES"
    return 0
  fi

  git -C "$repo_root" diff --no-ext-diff --no-index /dev/null "$file" || true
}

tracked_file_diff_for_prompt() {
  local repo_root="$1"
  local file="$2"
  local has_head="$3"
  local file_diff pathspec

  pathspec=$(git_literal_pathspec "$file")

  if [ "$has_head" = true ]; then
    file_diff=$(git -C "$repo_root" diff --no-ext-diff HEAD -- "$pathspec")
  else
    file_diff=$(git -C "$repo_root" diff --no-ext-diff --cached -- "$pathspec")
  fi

  if [ "${#file_diff}" -gt "$MAX_COMMIT_PLAN_FILE_DIFF_CHARS" ]; then
    debug_log "Omitting diff for '$file' because ${#file_diff} chars exceeds ${MAX_COMMIT_PLAN_FILE_DIFF_CHARS}"
    printf '[Omitted diff for %s because its diff size (%s chars) exceeds the prompt limit per file (%s chars).]\n' \
      "$file" "${#file_diff}" "$MAX_COMMIT_PLAN_FILE_DIFF_CHARS"
    return 0
  fi

  printf '%s\n' "$file_diff"
}

file_diff_for_prompt() {
  local repo_root="$1"
  local file="$2"
  local has_head="$3"
  local pathspec

  pathspec=$(git_literal_pathspec "$file")
  if git -C "$repo_root" ls-files --error-unmatch -- "$pathspec" >/dev/null 2>&1; then
    tracked_file_diff_for_prompt "$repo_root" "$file" "$has_head"
    return 0
  fi

  added_file_diff_for_prompt "$repo_root" "$file"
}

collect_changes_diff() {
  local changed_files_ref_name="$1"
  local repo_root file file_diff
  local has_head=false
  local diff_output=''
  local -A untracked_file_set=()
  local -n changed_files_ref="$changed_files_ref_name"

  repo_root=$(git_repo_root)

  if git rev-parse --verify HEAD >/dev/null 2>&1; then
    has_head=true
  fi

  while IFS= read -r -d '' file; do
    untracked_file_set["$file"]=1
  done < <(git -C "$repo_root" ls-files -z --others --exclude-standard)

  for file in "${changed_files_ref[@]}"; do
    if [ -n "${untracked_file_set[$file]:-}" ]; then
      file_diff=$(added_file_diff_for_prompt "$repo_root" "$file")
    else
      file_diff=$(tracked_file_diff_for_prompt "$repo_root" "$file" "$has_head")
    fi
    if [ -z "$file_diff" ]; then
      continue
    fi

    if [ -n "$diff_output" ]; then
      diff_output+=$'\n'
    fi
    diff_output+="$file_diff"

    if [ "${#diff_output}" -gt "$MAX_COMMIT_PLAN_DIFF_CHARS" ]; then
      debug_log "Stopping diff collection after reaching ${MAX_COMMIT_PLAN_DIFF_CHARS} chars"
      diff_output+=$'\n[Stopped collecting additional diffs after reaching the prompt diff budget.]'
      break
    fi
  done

  printf '%s\n' "$diff_output"
}

truncate_commit_plan_section() {
  local section_name="$1"
  local text="$2"
  local max_chars="$3"
  local notice keep_chars

  if [ "${#text}" -le "$max_chars" ]; then
    printf '%s\n' "$text"
    return 0
  fi

  debug_log "Truncating ${section_name} from ${#text} chars to ${max_chars}"

  notice=$'\n'
  notice+="[Truncated ${section_name} to fit provider message limits.]"
  keep_chars=$((max_chars - ${#notice}))
  if [ "$keep_chars" -lt 0 ]; then
    keep_chars=0
  fi

  printf '%s%s\n' "${text:0:$keep_chars}" "$notice"
}
