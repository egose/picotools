#!/usr/bin/env bash

if [ "${PICOTOOLS_GIT_COMMIT_MODEL_SH_LOADED:-0}" -eq 1 ]; then
  return 0
fi
PICOTOOLS_GIT_COMMIT_MODEL_SH_LOADED=1

# Contract: model helpers accept scalar profile/model/prompt arguments, store
# prompt/response bytes in restrictive temp files, print provider stdout on
# success, and return provider/limit failures to the caller. Required callbacks:
# debug_enabled, debug_log, run_model_profile, register_tmpfile, and
# cleanup_tmpfiles. Required globals: GIT_COMMIT_TMPFILES,
# LAST_RAW_COMMIT_PLAN_RESPONSE, and MAX_COMMIT_MODEL_* defaults.

should_retry_with_additional_model() {
  local error_output="$1"

  case "$error_output" in
  *'Error: request failed with HTTP 429'* | *'Error: request failed with HTTP 503'*)
    return 0
    ;;
  esac

  return 1
}

commit_plan_response_byte_limit() {
  printf '%s\n' "${GIT_COMMIT_MODEL_RESPONSE_MAX_BYTES:-${MAX_COMMIT_MODEL_RESPONSE_BYTES:-1048576}}"
}

commit_plan_diagnostic_byte_limit() {
  printf '%s\n' "${GIT_COMMIT_MODEL_DIAGNOSTIC_MAX_BYTES:-${MAX_COMMIT_MODEL_DIAGNOSTIC_BYTES:-4096}}"
}

make_restrictive_tmpfile() {
  local path old_umask

  old_umask=$(umask)
  umask 077
  path=$(mktemp) || {
    umask "$old_umask"
    return 1
  }
  umask "$old_umask"
  chmod 600 "$path"
  printf '%s\n' "$path"
}

cleanup_tmpfiles_for_signal() {
  local status=$?

  cleanup_tmpfiles
  trap - HUP INT TERM
  exit "$status"
}

install_git_commit_cleanup_traps() {
  trap cleanup_tmpfiles EXIT
  trap cleanup_tmpfiles_for_signal HUP INT TERM
}

redact_commit_plan_diagnostic_text() {
  local text="$1"
  local name value

  while IFS='=' read -r name value; do
    case "$name" in
    *TOKEN* | *SECRET* | *PASSWORD* | *PAT* | *KEY*)
      if [ "${#value}" -ge 4 ]; then
        text=${text//"$value"/[REDACTED]}
      fi
      ;;
    esac
  done < <(env)

  printf '%s' "$text"
}

escape_commit_plan_diagnostic_text() {
  local text="$1"

  if command -v perl >/dev/null 2>&1; then
    printf '%s' "$text" | perl -CS -pe 's/\\/\\\\/g; s/([\x00-\x1f\x7f])/sprintf("\\u%04x", ord($1))/ge'
    return 0
  fi

  text=${text//\\/\\\\}
  text=${text//$'\n'/\\n}
  text=${text//$'\r'/\\r}
  text=${text//$'\t'/\\t}
  text=${text//$'\033'/\\u001b}
  printf '%s' "$text"
}

commit_plan_diagnostic_excerpt() {
  local text="$1"
  local limit redacted original_bytes excerpt suffix=''
  local LC_ALL=C

  limit=$(commit_plan_diagnostic_byte_limit)
  redacted=$(redact_commit_plan_diagnostic_text "$text")
  original_bytes=${#redacted}
  if [ "$original_bytes" -gt "$limit" ]; then
    excerpt=${redacted:0:limit}
    suffix=" [truncated to ${limit} of ${original_bytes} bytes]"
  else
    excerpt="$redacted"
  fi

  printf '%s%s\n' "$(escape_commit_plan_diagnostic_text "$excerpt")" "$suffix"
}

debug_commit_plan_response_diagnostic() {
  local response="$1"
  local limit excerpt

  debug_enabled || return 0

  limit=$(commit_plan_diagnostic_byte_limit)
  excerpt=$(commit_plan_diagnostic_excerpt "$response")
  printf '[git-commit] Model response diagnostic (redacted, JSON-escaped, max %s bytes): %s\n' "$limit" "$excerpt" >&2
}

ensure_commit_plan_response_within_limit() {
  local response_file="$1"
  local stderr_file="$2"
  local limit bytes

  limit=$(commit_plan_response_byte_limit)
  bytes=$(wc -c <"$response_file")
  bytes=${bytes//[[:space:]]/}
  if [ "$bytes" -le "$limit" ]; then
    return 0
  fi

  printf 'Error: model response exceeded %s bytes\n' "$limit" >"$stderr_file"
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
  local response_file="$6"
  local output status=0

  debug_log "Requesting commit plan from model-profile '$profile' model '$model'"
  if run_model_profile ask "$profile" --model "$model" --system-message-file "$system_message_file" --message-file "$user_message_file" >"$response_file" 2>"$stderr_file"; then
    if [ -s "$stderr_file" ]; then
      print_error_output "$(<"$stderr_file")"
    fi
    ensure_commit_plan_response_within_limit "$response_file" "$stderr_file" || return 1
    output=$(<"$response_file")
    debug_log "Received commit plan response ($(wc -c <"$response_file") bytes)"
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
  local system_message_file user_message_file stderr_file response_file output status=0 error_output=''

  debug_log "Prompt sizes: system=${#system_message} chars, user=${#user_message} chars"

  system_message_file=$(make_restrictive_tmpfile)
  user_message_file=$(make_restrictive_tmpfile)
  stderr_file=$(make_restrictive_tmpfile)
  response_file=$(make_restrictive_tmpfile)
  register_tmpfile "$system_message_file"
  register_tmpfile "$user_message_file"
  register_tmpfile "$stderr_file"
  register_tmpfile "$response_file"
  install_git_commit_cleanup_traps
  printf '%s' "$system_message" >"$system_message_file"
  printf '%s' "$user_message" >"$user_message_file"

  if output=$(request_commit_plan_once "$profile" "$model" "$system_message_file" "$user_message_file" "$stderr_file" "$response_file"); then
    record_raw_commit_plan_response "$output"
    printf '%s\n' "$output"
    cleanup_tmpfiles
    return 0
  else
    status=$?
  fi
  error_output=$(<"$stderr_file")

  if [ -n "$additional_profile" ] && [ -n "$additional_model" ] && should_retry_with_additional_model "$error_output"; then
    debug_log "Primary model request failed with a retryable status; retrying with additional profile '$additional_profile' model '$additional_model'"
    : >"$stderr_file"
    : >"$response_file"
    if output=$(request_commit_plan_once "$additional_profile" "$additional_model" "$system_message_file" "$user_message_file" "$stderr_file" "$response_file"); then
      record_raw_commit_plan_response "$output"
      printf '%s\n' "$output"
      cleanup_tmpfiles
      return 0
    else
      status=$?
    fi
    error_output=$(<"$stderr_file")
  fi

  if [ -n "$error_output" ]; then
    print_error_output "$error_output"
  fi

  cleanup_tmpfiles
  return "$status"
}
