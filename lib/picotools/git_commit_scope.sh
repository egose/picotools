#!/usr/bin/env bash

if [ "${PICOTOOLS_GIT_COMMIT_SCOPE_SH_LOADED:-0}" -eq 1 ]; then
  return 0
fi
PICOTOOLS_GIT_COMMIT_SCOPE_SH_LOADED=1

# Contract: scope helpers take scalar inputs or array namerefs, print the
# resolved scope to stdout, and return nonzero only when a required Git query
# fails. Required dependency: git_repo_root from git_commit_workspace.sh.
derive_scope_from_branch() {
  local branch="$1"
  local last_segment

  if [[ "$branch" != */* ]]; then
    printf '\n'
    return 0
  fi

  last_segment=${branch##*/}
  if [[ "$last_segment" =~ ^(.+)_([0-9]+)$ ]]; then
    last_segment=${BASH_REMATCH[1]}
  fi

  if [[ "$last_segment" =~ ^([0-9]+)([_-].*)?$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi

  printf '%s\n' "$last_segment"
}

scope_is_placeholder() {
  local scope="$1"

  case "$scope" in
  *'{{'* | *'}}'*)
    return 0
    ;;
  esac

  return 1
}

print_resolved_scope() {
  local scope="$1"

  if scope_is_placeholder "$scope"; then
    printf '\n'
    return 0
  fi

  printf '%s\n' "$scope"
}

repo_has_workspace_manifest() {
  local repo_root="$1"
  local manifest

  for manifest in pnpm-workspace.yaml lerna.json nx.json turbo.json rush.json go.work; do
    if [ -f "$repo_root/$manifest" ]; then
      return 0
    fi
  done

  return 1
}

package_json_declares_workspaces() {
  local repo_root="$1"
  local package_json="$repo_root/package.json"

  if [ ! -f "$package_json" ]; then
    return 1
  fi

  grep -Eq '"workspaces"[[:space:]]*:' "$package_json"
}

count_nested_module_manifests() {
  local repo_root="$1"
  local path count=0

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    case "$path" in
    package.json | pyproject.toml | go.mod | Cargo.toml)
      continue
      ;;
    */package.json | */pyproject.toml | */go.mod | */Cargo.toml)
      count=$((count + 1))
      if [ "$count" -ge 2 ]; then
        printf '%s\n' "$count"
        return 0
      fi
      ;;
    esac
  done < <(git -C "$repo_root" ls-files --cached --others --exclude-standard -- '*/package.json' '*/pyproject.toml' '*/go.mod' '*/Cargo.toml')

  printf '%s\n' "$count"
}

repo_is_monorepo() {
  local repo_root="$1"
  local nested_manifest_count

  if repo_has_workspace_manifest "$repo_root" || package_json_declares_workspaces "$repo_root"; then
    return 0
  fi

  nested_manifest_count=$(count_nested_module_manifests "$repo_root")
  [ "$nested_manifest_count" -ge 2 ]
}

module_dir_for_file() {
  local repo_root="$1"
  local file="$2"
  local dir parent

  case "$file" in
  */*)
    dir=${file%/*}
    ;;
  *)
    return 1
    ;;
  esac

  while [ -n "$dir" ] && [ "$dir" != '.' ]; do
    if [ -f "$repo_root/$dir/package.json" ] || [ -f "$repo_root/$dir/pyproject.toml" ] || [ -f "$repo_root/$dir/go.mod" ] || [ -f "$repo_root/$dir/Cargo.toml" ]; then
      printf '%s\n' "$dir"
      return 0
    fi

    parent=${dir%/*}
    if [ "$parent" = "$dir" ]; then
      break
    fi
    dir="$parent"
  done

  return 1
}

package_name_from_manifest() {
  local package_json="$1"
  local line
  local name_pattern='"name"[[:space:]]*:[[:space:]]*"([^"]+)"'

  [ -f "$package_json" ] || return 1

  while IFS= read -r line; do
    if [[ "$line" =~ $name_pattern ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}"
      return 0
    fi
  done <"$package_json"

  return 1
}

module_scope_name() {
  local repo_root="$1"
  local module_dir="$2"
  local package_name

  package_name=$(package_name_from_manifest "$repo_root/$module_dir/package.json" || true)
  if [ -n "$package_name" ]; then
    printf '%s\n' "${package_name##*/}"
    return 0
  fi

  printf '%s\n' "${module_dir##*/}"
}

derive_scope_from_monorepo() {
  local changed_files_ref_name="$1"
  local repo_root file module_dir scope=''
  local -A seen_modules=()
  local -n changed_files_ref="$changed_files_ref_name"

  repo_root=$(git_repo_root) || return 1
  if ! repo_is_monorepo "$repo_root"; then
    printf '\n'
    return 0
  fi

  for file in "${changed_files_ref[@]}"; do
    module_dir=$(module_dir_for_file "$repo_root" "$file" || true)
    if [ -z "$module_dir" ] || [ -n "${seen_modules[$module_dir]:-}" ]; then
      continue
    fi

    seen_modules[$module_dir]=1
    if [ -n "$scope" ] && [ "$scope" != "$module_dir" ]; then
      printf '\n'
      return 0
    fi
    scope="$module_dir"
  done

  if [ -z "$scope" ]; then
    printf '\n'
    return 0
  fi

  module_scope_name "$repo_root" "$scope"
}

resolve_scope() {
  local branch="$1"
  local scope_override="$2"
  local no_scope="$3"
  local changed_files_ref_name="$4"
  local scope

  if [ "$no_scope" = 'true' ]; then
    printf '\n'
    return 0
  fi

  if [ -n "$scope_override" ]; then
    print_resolved_scope "$scope_override"
    return 0
  fi

  scope=$(derive_scope_from_branch "$branch")
  if [ -n "$scope" ]; then
    print_resolved_scope "$scope"
    return 0
  fi

  scope=$(derive_scope_from_monorepo "$changed_files_ref_name")
  print_resolved_scope "$scope"
}
