#!/usr/bin/env bash

if [ "${PICOTOOLS_GIT_COMMIT_OPTIONS_SH_LOADED:-0}" -eq 1 ]; then
  return 0
fi
PICOTOOLS_GIT_COMMIT_OPTIONS_SH_LOADED=1

# Contract: parse_run_options <assoc-output-ref> <array-output-ref> [argv...]
# Populates caller-owned option/path state, returns nonzero on invalid input,
# writes diagnostics to stderr, and requires load_scope_paths_file from
# git_commit_workspace.sh for --path-file expansion.
parse_run_options() {
  local options_ref_name="$1"
  local selected_paths_ref_name="$2"
  shift 2
  local -a path_file_entries=()
  local -n options_ref="$options_ref_name"
  local -n selected_paths_ref="$selected_paths_ref_name"

  options_ref=()
  options_ref["scope_override"]=''
  options_ref["no_scope"]=false
  options_ref["apply_commits"]=false
  options_ref["push_commits"]=false
  options_ref["create_pr"]=false
  options_ref["pr_base_branch"]=''
  options_ref["pre_commit_retries"]=2
  options_ref["debug_mode"]=false
  options_ref["relaxed_plan"]=false
  selected_paths_ref=()

  while [ "$#" -gt 0 ]; do
    case "$1" in
    --apply)
      options_ref["apply_commits"]=true
      shift
      ;;
    --debug)
      options_ref["debug_mode"]=true
      shift
      ;;
    --relaxed-plan)
      options_ref["relaxed_plan"]=true
      shift
      ;;
    --push)
      options_ref["push_commits"]=true
      shift
      ;;
    --pr)
      options_ref["create_pr"]=true
      if [ "$#" -ge 2 ] && [[ "$2" != --* ]]; then
        options_ref["pr_base_branch"]="$2"
        shift 2
      else
        shift
      fi
      ;;
    --pr=*)
      options_ref["create_pr"]=true
      options_ref["pr_base_branch"]="${1#--pr=}"
      shift
      ;;
    --pre-commit-retries)
      if [ "$#" -lt 2 ] || [ -z "$2" ]; then
        echo 'Error: --pre-commit-retries requires a value' >&2
        return 1
      fi
      if ! [[ "$2" =~ ^[0-9]+$ ]]; then
        echo 'Error: --pre-commit-retries must be a non-negative integer' >&2
        return 1
      fi
      options_ref["pre_commit_retries"]="$2"
      shift 2
      ;;
    --pre-commit-retries=*)
      options_ref["pre_commit_retries"]="${1#--pre-commit-retries=}"
      if [ -z "${options_ref["pre_commit_retries"]}" ]; then
        echo 'Error: --pre-commit-retries requires a value' >&2
        return 1
      fi
      if ! [[ "${options_ref["pre_commit_retries"]}" =~ ^[0-9]+$ ]]; then
        echo 'Error: --pre-commit-retries must be a non-negative integer' >&2
        return 1
      fi
      shift
      ;;
    --path)
      if [ "$#" -lt 2 ] || [ -z "$2" ]; then
        echo 'Error: --path requires a value' >&2
        return 1
      fi
      selected_paths_ref+=("$2")
      shift 2
      ;;
    --path=*)
      if [ -z "${1#--path=}" ]; then
        echo 'Error: --path requires a value' >&2
        return 1
      fi
      selected_paths_ref+=("${1#--path=}")
      shift
      ;;
    --path-file)
      if [ "$#" -lt 2 ] || [ -z "$2" ]; then
        echo 'Error: --path-file requires a value' >&2
        return 1
      fi
      load_scope_paths_file "$2" path_file_entries || return $?
      selected_paths_ref+=("${path_file_entries[@]}")
      shift 2
      ;;
    --path-file=*)
      if [ -z "${1#--path-file=}" ]; then
        echo 'Error: --path-file requires a value' >&2
        return 1
      fi
      load_scope_paths_file "${1#--path-file=}" path_file_entries || return $?
      selected_paths_ref+=("${path_file_entries[@]}")
      shift
      ;;
    --scope)
      if [ "$#" -lt 2 ] || [ -z "$2" ]; then
        echo 'Error: --scope requires a value' >&2
        return 1
      fi
      options_ref["scope_override"]="$2"
      options_ref["no_scope"]=false
      shift 2
      ;;
    --scope=*)
      options_ref["scope_override"]="${1#--scope=}"
      if [ -z "${options_ref["scope_override"]}" ]; then
        echo 'Error: --scope requires a value' >&2
        return 1
      fi
      options_ref["no_scope"]=false
      shift
      ;;
    --no-scope)
      options_ref["scope_override"]=''
      options_ref["no_scope"]=true
      shift
      ;;
    *)
      echo "Error: unknown option '$1'" >&2
      usage >&2
      return 1
      ;;
    esac
  done

  if [ "${options_ref["create_pr"]}" = 'true' ]; then
    options_ref["push_commits"]=true
  fi

  if [ "${options_ref["push_commits"]}" = 'true' ]; then
    options_ref["apply_commits"]=true
  fi

  return 0
}
