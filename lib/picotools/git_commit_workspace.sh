#!/usr/bin/env bash

if [ "${PICOTOOLS_GIT_COMMIT_WORKSPACE_SH_LOADED:-0}" -eq 1 ]; then
  return 0
fi
PICOTOOLS_GIT_COMMIT_WORKSPACE_SH_LOADED=1

git_repo_root() {
  git rev-parse --show-toplevel
}

collect_changed_files() {
  local repo_root file
  local has_head=false
  local -A seen=()
  local -a files=()

  repo_root=$(git_repo_root)

  if git rev-parse --verify HEAD >/dev/null 2>&1; then
    has_head=true
  fi

  if [ "$has_head" = true ]; then
    while IFS= read -r file; do
      if [ -n "$file" ] && [ -z "${seen[$file]:-}" ]; then
        seen[$file]=1
        files+=("$file")
      fi
    done < <(git -C "$repo_root" diff --name-only HEAD --)
  else
    while IFS= read -r file; do
      if [ -n "$file" ] && [ -z "${seen[$file]:-}" ]; then
        seen[$file]=1
        files+=("$file")
      fi
    done < <(git -C "$repo_root" diff --name-only --cached --)
  fi

  while IFS= read -r file; do
    if [ -n "$file" ] && [ -z "${seen[$file]:-}" ]; then
      seen[$file]=1
      files+=("$file")
    fi
  done < <(git -C "$repo_root" ls-files --others --exclude-standard)

  printf '%s\n' "${files[@]}"
}

changed_files_include_path() {
  local changed_files="$1"
  local target_path="$2"
  local file

  while IFS= read -r file; do
    if [ "$file" = "$target_path" ]; then
      return 0
    fi
  done <<<"$changed_files"

  return 1
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
  local file_diff

  if [ "$has_head" = true ]; then
    file_diff=$(git -C "$repo_root" diff --no-ext-diff HEAD -- "$file")
  else
    file_diff=$(git -C "$repo_root" diff --no-ext-diff --cached -- "$file")
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

  if git -C "$repo_root" ls-files --error-unmatch -- "$file" >/dev/null 2>&1; then
    tracked_file_diff_for_prompt "$repo_root" "$file" "$has_head"
    return 0
  fi

  added_file_diff_for_prompt "$repo_root" "$file"
}

collect_changes_diff() {
  local changed_files="$1"
  local repo_root file file_diff
  local has_head=false
  local diff_output=''

  repo_root=$(git_repo_root)

  if git rev-parse --verify HEAD >/dev/null 2>&1; then
    has_head=true
  fi

  while IFS= read -r file; do
    [ -n "$file" ] || continue
    file_diff=$(file_diff_for_prompt "$repo_root" "$file" "$has_head")
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
  done <<<"$changed_files"

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
