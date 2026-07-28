#!/usr/bin/env bash

if [ "${PICOTOOLS_GIT_COMMIT_MODEL_SH_LOADED:-0}" -eq 1 ]; then
  return 0
fi
PICOTOOLS_GIT_COMMIT_MODEL_SH_LOADED=1

should_retry_with_additional_model() {
  local error_output="$1"

  case "$error_output" in
  *'Error: request failed with HTTP 429'* | *'Error: request failed with HTTP 503'*)
    return 0
    ;;
  esac

  return 1
}

print_error_output() {
  local error_output="$1"

  if [ -z "$error_output" ]; then
    return 0
  fi

  printf '%s' "$error_output" >&2
  case "$error_output" in
  *$'\n')
    ;;
  *)
    printf '\n' >&2
    ;;
  esac
}

record_raw_commit_plan_response() {
  LAST_RAW_COMMIT_PLAN_RESPONSE="$1"
}

print_raw_commit_plan_response() {
  if [ -z "$LAST_RAW_COMMIT_PLAN_RESPONSE" ]; then
    return 0
  fi

  printf 'Raw model response:\n%s\n' "$LAST_RAW_COMMIT_PLAN_RESPONSE" >&2
}

request_commit_plan_once() {
  local profile="$1"
  local model="$2"
  local system_message_file="$3"
  local user_message_file="$4"
  local stderr_file="$5"
  local output status=0

  debug_log "Requesting commit plan from model-profile '$profile' model '$model'"
  if output=$(run_model_profile ask "$profile" --model "$model" --system-message-file "$system_message_file" --message-file "$user_message_file" 2>"$stderr_file"); then
    if [ -s "$stderr_file" ]; then
      print_error_output "$(<"$stderr_file")"
    fi
    debug_log "Received commit plan response (${#output} chars)"
    printf '%s\n' "$output"
    return 0
  else
    status=$?
  fi

  return "$status"
}

request_commit_plan() {
  local profile="$1"
  local model="$2"
  local additional_profile="$3"
  local additional_model="$4"
  local system_message="$5"
  local user_message="$6"
  local system_message_file user_message_file stderr_file output status=0 error_output=''

  debug_log "Prompt sizes: system=${#system_message} chars, user=${#user_message} chars"

  system_message_file=$(mktemp)
  user_message_file=$(mktemp)
  stderr_file=$(mktemp)
  register_tmpfile "$system_message_file"
  register_tmpfile "$user_message_file"
  register_tmpfile "$stderr_file"
  trap 'cleanup_tmpfiles' EXIT
  printf '%s' "$system_message" >"$system_message_file"
  printf '%s' "$user_message" >"$user_message_file"

  if output=$(request_commit_plan_once "$profile" "$model" "$system_message_file" "$user_message_file" "$stderr_file"); then
    record_raw_commit_plan_response "$output"
    printf '%s\n' "$output"
    return 0
  else
    status=$?
  fi
  error_output=$(<"$stderr_file")

  if [ -n "$additional_profile" ] && [ -n "$additional_model" ] && should_retry_with_additional_model "$error_output"; then
    debug_log "Primary model request failed with a retryable status; retrying with additional profile '$additional_profile' model '$additional_model'"
    : >"$stderr_file"
    if output=$(request_commit_plan_once "$additional_profile" "$additional_model" "$system_message_file" "$user_message_file" "$stderr_file"); then
      record_raw_commit_plan_response "$output"
      printf '%s\n' "$output"
      return 0
    else
      status=$?
    fi
    error_output=$(<"$stderr_file")
  fi

  if [ -n "$error_output" ]; then
    print_error_output "$error_output"
  fi

  return "$status"
}
