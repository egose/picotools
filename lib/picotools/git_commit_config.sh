#!/usr/bin/env bash

if [ "${PICOTOOLS_GIT_COMMIT_CONFIG_SH_LOADED:-0}" -eq 1 ]; then
  return 0
fi
PICOTOOLS_GIT_COMMIT_CONFIG_SH_LOADED=1

# Contract: configuration and tool-command helpers take scalar arguments and
# print requested values to stdout. They return nonzero with stderr diagnostics
# on failure. Required callbacks/globals: SCRIPT_DIR, debug_enabled, debug_log,
# register_tmpfile, picotools_resolve_tool_command, and picotools UI prompts.
config_dir() {
  printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/git-commit"
}

config_file() {
  printf '%s/config\n' "$(config_dir)"
}

ensure_config_dir() {
  mkdir -p "$(config_dir)"
}

git_api_profiles_dir() {
  printf '%s\n' "${XDG_DATA_HOME:-$HOME/.local/share}/git-api/profiles"
}

list_git_api_profiles() {
  local profiles_dir
  local profile_dir

  profiles_dir=$(git_api_profiles_dir)
  for profile_dir in "$profiles_dir"/*; do
    [ -d "$profile_dir" ] || continue
    [ -f "$profile_dir/token" ] || continue
    basename "$profile_dir"
  done
}

write_config_value() {
  local key="$1"
  local value="$2"

  ensure_config_dir
  git config -f "$(config_file)" "$key" "$value"
}

unset_config_value() {
  local key="$1"

  if [ -f "$(config_file)" ]; then
    git config -f "$(config_file)" --unset-all "$key" 2>/dev/null || true
  fi
}

read_config_value_optional() {
  local key="$1"

  git config -f "$(config_file)" --get "$key" 2>/dev/null || true
}

model_profile_command() {
  picotools_resolve_tool_command "$SCRIPT_DIR" MODEL_PROFILE_BIN model-profile
}

git_api_command() {
  picotools_resolve_tool_command "$SCRIPT_DIR" GIT_API_BIN git-api
}

git_profile_command() {
  picotools_resolve_tool_command "$SCRIPT_DIR" GIT_PROFILE_BIN git-profile
}

run_git_api() {
  local tool
  local repository_token="${GIT_COMMIT_GIT_API_TOKEN:-}"
  local configured_profile="${GIT_COMMIT_GIT_API_PROFILE:-}"

  tool=$(git_api_command) || return 1
  if [ -n "$repository_token" ]; then
    if debug_enabled; then
      printf '%s' "$repository_token" | "$tool" --debug --token-stdin "$@"
      return $?
    fi

    printf '%s' "$repository_token" | "$tool" --token-stdin "$@"
    return $?
  fi

  if debug_enabled; then
    if [ -n "$configured_profile" ]; then
      "$tool" --debug --profile "$configured_profile" "$@"
      return $?
    fi
    "$tool" --debug "$@"
    return $?
  fi

  if [ -n "$configured_profile" ]; then
    "$tool" --profile "$configured_profile" "$@"
    return $?
  fi

  "$tool" "$@"
}

run_git_profile() {
  local tool

  tool=$(git_profile_command) || return 1
  "$tool" "$@"
}

run_model_profile() {
  local tool

  tool=$(model_profile_command) || return 1
  if debug_enabled; then
    "$tool" --debug "$@"
    return $?
  fi

  "$tool" "$@"
}

configure_tool() {
  local profile model additional_profile='' additional_model='' git_api_profile=''
  local selection_status=0
  local -a profiles=()
  local -a models=()
  local -a additional_profiles=()
  local -a git_api_profiles=()
  local candidate_profile

  picotools_ui_section 'Configure Git Commit'
  picotools_ui_step 1 3 'Choose primary model profile'
  model_profile_command >/dev/null || return 1
  mapfile -t profiles < <(run_model_profile profiles)
  if [ "${#profiles[@]}" -eq 0 ]; then
    echo 'Error: no model profiles found' >&2
    return 1
  fi

  profile=$(picotools_prompt_select_value 'Profiles' 'Select profile' 1 "${profiles[@]}") || selection_status=$?
  if [ "$selection_status" -ne 0 ]; then
    picotools_cancel
    return 1
  fi
  selection_status=0
  mapfile -t models < <(run_model_profile models "$profile")
  if [ "${#models[@]}" -eq 0 ]; then
    echo "Error: no models configured for profile '$profile'" >&2
    return 1
  fi

  model=$(picotools_prompt_select_value 'Models' 'Select model' 1 "${models[@]}") || selection_status=$?
  if [ "$selection_status" -ne 0 ]; then
    picotools_cancel
    return 1
  fi
  selection_status=0

  for candidate_profile in "${profiles[@]}"; do
    if [ "$candidate_profile" != "$profile" ]; then
      additional_profiles+=("$candidate_profile")
    fi
  done

  if [ "${#additional_profiles[@]}" -gt 0 ]; then
    picotools_ui_step 2 3 'Choose optional fallback profile'
    additional_profile=$(picotools_prompt_select_optional_value 'Additional Profile (Optional)' 'Select additional profile' 'None' 1 "${additional_profiles[@]}") || selection_status=$?
    if [ "$selection_status" -ne 0 ]; then
      picotools_cancel
      return 1
    fi
    selection_status=0

    if [ -n "$additional_profile" ]; then
      mapfile -t models < <(run_model_profile models "$additional_profile")
      if [ "${#models[@]}" -eq 0 ]; then
        echo "Error: no models configured for profile '$additional_profile'" >&2
        return 1
      fi

      additional_model=$(picotools_prompt_select_value 'Additional Models' 'Select additional model' 1 "${models[@]}") || selection_status=$?
      if [ "$selection_status" -ne 0 ]; then
        picotools_cancel
        return 1
      fi
      selection_status=0
    fi
  fi

  mapfile -t git_api_profiles < <(list_git_api_profiles)
  if [ "${#git_api_profiles[@]}" -gt 0 ]; then
    picotools_ui_step 3 3 'Choose optional git-api profile'
    git_api_profile=$(picotools_prompt_select_optional_value 'git-api Profile (Optional)' 'Select git-api profile' 'None' 1 "${git_api_profiles[@]}") || selection_status=$?
    if [ "$selection_status" -ne 0 ]; then
      picotools_cancel
      return 1
    fi
    selection_status=0
  fi

  picotools_ui_summary 'Review Git Commit Configuration' \
    "Primary profile: ${profile}" \
    "Primary model: ${model}" \
    "Fallback profile: ${additional_profile:--}" \
    "Fallback model: ${additional_model:--}" \
    "git-api profile: ${git_api_profile:--}"

  write_config_value model.profile "$profile"
  write_config_value model.name "$model"
  if [ -n "$git_api_profile" ]; then
    write_config_value git-api.profile "$git_api_profile"
  else
    unset_config_value git-api.profile
  fi
  if [ -n "$additional_profile" ] && [ -n "$additional_model" ]; then
    write_config_value model.additional.profile "$additional_profile"
    write_config_value model.additional.name "$additional_model"
    if [ -n "$git_api_profile" ]; then
      echo "Configured git-commit with profile '$profile' and model '$model', plus additional profile '$additional_profile' and model '$additional_model', using git-api profile '$git_api_profile'."
      return 0
    fi

    echo "Configured git-commit with profile '$profile' and model '$model', plus additional profile '$additional_profile' and model '$additional_model'."
    return 0
  fi

  unset_config_value model.additional.profile
  unset_config_value model.additional.name
  picotools_ui_summary 'Git Commit Configured' \
    "Profile: ${profile}" \
    "Model: ${model}" \
    "git-api: ${git_api_profile:--}"
  if [ -n "$git_api_profile" ]; then
    echo "Configured git-commit with profile '$profile' and model '$model', using git-api profile '$git_api_profile'."
    return 0
  fi

  echo "Configured git-commit with profile '$profile' and model '$model'."
}

load_configuration() {
  local profile model additional_profile additional_model git_api_profile

  profile=$(read_config_value_optional model.profile)
  model=$(read_config_value_optional model.name)
  additional_profile=$(read_config_value_optional model.additional.profile)
  additional_model=$(read_config_value_optional model.additional.name)
  git_api_profile=$(read_config_value_optional git-api.profile)

  if [ -z "$profile" ] || [ -z "$model" ]; then
    echo 'Warning: git-commit is not configured. Run git-commit configure.' >&2
    return 1
  fi

  printf '%s\n%s\n%s\n%s\n%s\n' "$profile" "$model" "$additional_profile" "$additional_model" "$git_api_profile"
}

load_run_configuration() {
  local config_values

  debug_log 'Loading configured model profile'
  config_values=$(load_configuration) || return 1
  printf '%s\n' "$config_values"
}

resolve_repository_git_api_auth() {
  local token stderr_file stderr_output

  GIT_COMMIT_GIT_API_TOKEN=''
  stderr_file=$(mktemp) || return 1
  register_tmpfile "$stderr_file"

  debug_log 'Checking for a repository git profile PAT'
  if token=$(run_git_profile token 2>"$stderr_file"); then
    GIT_COMMIT_GIT_API_TOKEN="$token"
    debug_log 'Using repository git profile PAT for pull request API calls'
    return 0
  fi

  stderr_output=$(<"$stderr_file")
  case "$stderr_output" in
  'Error: no git profile is recorded in this repository' | "Error: PAT not configured for profile '"*"'")
    debug_log 'No repository git profile PAT is available; falling back to git-api profile resolution'
    return 0
    ;;
  '')
    echo 'Error: failed to resolve repository git profile PAT' >&2
    ;;
  *)
    printf '%s\n' "$stderr_output" >&2
    ;;
  esac

  return 1
}
