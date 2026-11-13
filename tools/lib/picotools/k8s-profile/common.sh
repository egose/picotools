#!/usr/bin/env bash

if [ "${PICOTOOLS_K8S_PROFILE_COMMON_SH_LOADED:-0}" -eq 1 ]; then
  return 0
fi
PICOTOOLS_K8S_PROFILE_COMMON_SH_LOADED=1

K8S_PROFILE_TMP_DIR=''
K8S_PROFILE_RETAIN_RECOVERY=false
K8S_PROFILE_STAGE_FILES=()
K8S_PROFILE_CREATED_DIRS=()
K8S_PROFILE_CREATED_DIR_KEYS=()
K8S_PROFILE_PROMPT_SERIAL=0
K8S_PROFILE_TTY_FD=''
K8S_PROFILE_TTY_STATE=''
K8S_PROFILE_TTY_ACTIVE=false
K8S_PROFILE_TTY_CURSOR_HIDDEN=false

k8s_profile_error() {
  printf 'Error: %s.\n' "$1" >&2
}

k8s_profile_require_dependencies() {
  if [ "${BASH_VERSINFO[0]}" -lt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 4 ]; }; then
    k8s_profile_error 'Bash 4.4 or newer is required'
    return 1
  fi
  picotools_require_command kubectl
  picotools_require_command jq
  picotools_require_commands awk mktemp chmod cp rm mkdir rmdir stat sha256sum cmp stty mv ln
  # GNU no-target-directory is required for safe rename/no-replace publication.
  if ! stat --version >/dev/null 2>&1 || ! mv --version >/dev/null 2>&1 || ! ln --version >/dev/null 2>&1 || ! stty --version >/dev/null 2>&1; then
    k8s_profile_error 'GNU coreutils stat, mv, ln, and stty are required for safe publication and terminal input'
    return 1
  fi
}

k8s_profile_init() {
  set +x
  set +a
  local workspace_parent="${TMPDIR:-/tmp}"
  if [ -n "$K8S_PROFILE_TMP_DIR" ]; then
    return 0
  fi
  umask 077
  if [[ "$workspace_parent" != /* ]]; then
    workspace_parent="$(pwd -P)/$workspace_parent"
  fi
  # Preserve lexical traversal when checking the actual location, including
  # relative TMPDIR and symlinks which a dot-dot could otherwise conceal.
  k8s_profile_check_ancestors "$workspace_parent/k8s-profile.workspace" true 'private workspace' || return 1
  if ! K8S_PROFILE_TMP_DIR=$(mktemp -d "$workspace_parent/k8s-profile.XXXXXX" 2>/dev/null); then
    k8s_profile_error 'unable to create a private workspace'
    return 1
  fi
  trap 'k8s_profile_cleanup "$?"' EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  if ! chmod 700 -- "$K8S_PROFILE_TMP_DIR" >/dev/null 2>&1; then
    k8s_profile_error 'unable to secure the private workspace'
    return 1
  fi
  # A 0700 directory inside a nonsticky writable ancestor can be renamed and
  # replaced by another user. Reject that before any config or Token is read.
  k8s_profile_check_ancestors "$K8S_PROFILE_TMP_DIR/diagnostics" true 'private workspace' || return 1
  : >"$K8S_PROFILE_TMP_DIR/diagnostics"
}

k8s_profile_cleanup() {
  local status="$1" index
  trap - EXIT
  # Do not interrupt recovery halfway through with a second handled signal.
  # SIGKILL remains outside the returned-failure/handled-signal guarantee.
  trap '' HUP INT TERM
  # Restore the original terminal before potentially lengthy file recovery.
  if ! k8s_profile_tty_restore; then
    status=1
  fi
  if [ "${K8S_PROFILE_TX_ACTIVE:-false}" = true ]; then
    if ! k8s_profile_tx_rollback; then
      status=1
    fi
  fi
  if declare -F k8s_profile_tx_release_locks >/dev/null; then
    k8s_profile_tx_release_locks
  fi
  if [ "${#K8S_PROFILE_STAGE_FILES[@]}" -gt 0 ]; then
    rm -f -- "${K8S_PROFILE_STAGE_FILES[@]}" >/dev/null 2>&1 || true
  fi
  for ((index = ${#K8S_PROFILE_CREATED_DIRS[@]} - 1; index >= 0; index--)); do
    if [ "$(stat --printf='%d:%i' -- "${K8S_PROFILE_CREATED_DIRS[$index]}" 2>/dev/null)" = "${K8S_PROFILE_CREATED_DIR_KEYS[$index]}" ]; then
      rmdir -- "${K8S_PROFILE_CREATED_DIRS[$index]}" >/dev/null 2>&1 || true
    fi
  done
  if [ -n "$K8S_PROFILE_TMP_DIR" ] && [ "$K8S_PROFILE_RETAIN_RECOVERY" != true ]; then
    rm -rf -- "$K8S_PROFILE_TMP_DIR" >/dev/null 2>&1 || true
  fi
  exit "$status"
}

# All kubectl/jq stdout and stderr are private until an explicit public projection.
# Even nonraw kubectl errors can include credentials from malformed input.
k8s_profile_jq() {
  local output="$1" message="$2"
  shift 2
  if ! jq "$@" >"$output" 2>"$K8S_PROFILE_TMP_DIR/diagnostics"; then
    k8s_profile_error "$message"
    return 1
  fi
}

k8s_profile_kubectl() {
  local output="$1" message="$2"
  shift 2
  if ! KUBECTL_KUBERC=false kubectl "$@" >"$output" 2>"$K8S_PROFILE_TMP_DIR/diagnostics"; then
    k8s_profile_error "$message"
    return 1
  fi
}

# Read one explicitly nonsecret JSON value without losing trailing newlines in
# external names. NUL is rejected by schema validation before this boundary.
k8s_profile_json_value() {
  local result_var="$1"
  shift
  k8s_profile_jq "$K8S_PROFILE_TMP_DIR/value" 'unable to inspect configuration' -j "$@" || return 1
  IFS= read -r -d '' "$result_var" <"$K8S_PROFILE_TMP_DIR/value"
}

# read's ordinary line mode silently discards NUL. A NUL-delimited one-character
# read distinguishes it from newline and EOF without putting input in an argv,
# environment variable, or external filter. Also require a completed input line.
k8s_profile_read_input_line() {
  set +x
  set +a
  local result_var="$1" k8s_profile_line_buffer='' k8s_profile_line_char=''
  local LC_ALL=C
  export -n k8s_profile_line_buffer k8s_profile_line_char
  while true; do
    if ! IFS= read -rs -d '' -n 1 k8s_profile_line_char; then
      unset k8s_profile_line_buffer k8s_profile_line_char
      return 1
    fi
    case "$k8s_profile_line_char" in
    '')
      unset k8s_profile_line_buffer k8s_profile_line_char
      return 2
      ;;
    $'\n')
      printf -v "$result_var" '%s' "$k8s_profile_line_buffer"
      unset k8s_profile_line_buffer k8s_profile_line_char
      return 0
      ;;
    *) k8s_profile_line_buffer+="$k8s_profile_line_char" ;;
    esac
  done
}

k8s_profile_input_error() {
  if [ "$1" -eq 2 ]; then
    k8s_profile_error 'input contains an unsupported NUL character'
  elif [ "$1" -eq 3 ]; then
    k8s_profile_error 'input contains an unsupported character'
  else
    k8s_profile_error 'input ended before required value was provided'
  fi
}

# Run operational prompts in the main shell, not command substitutions. The
# EXIT/signal cleanup must own the saved terminal fd/state even while reading.
# Values here are only ordinary inputs or indexes, never Token contents.
k8s_profile_capture_prompt() {
  local k8s_profile_result_var="$1" k8s_profile_result_file k8s_profile_result_status
  shift
  K8S_PROFILE_PROMPT_SERIAL=$((K8S_PROFILE_PROMPT_SERIAL + 1))
  k8s_profile_result_file="$K8S_PROFILE_TMP_DIR/prompt-$K8S_PROFILE_PROMPT_SERIAL"
  if "$@" >"$k8s_profile_result_file"; then
    IFS= read -r "${k8s_profile_result_var?}" <"$k8s_profile_result_file"
  else
    k8s_profile_result_status=$?
    return "$k8s_profile_result_status"
  fi
}

k8s_profile_tty_begin() {
  [ -t 0 ] || return 0
  if [ "$K8S_PROFILE_TTY_ACTIVE" = true ]; then
    k8s_profile_error 'terminal input is already active'
    return 1
  fi
  if ! { exec {K8S_PROFILE_TTY_FD}<&0; } 2>"$K8S_PROFILE_TMP_DIR/diagnostics"; then
    k8s_profile_error 'unable to save terminal input descriptor'
    return 1
  fi
  if ! K8S_PROFILE_TTY_STATE=$(stty -g <&"$K8S_PROFILE_TTY_FD" 2>"$K8S_PROFILE_TMP_DIR/diagnostics"); then
    exec {K8S_PROFILE_TTY_FD}<&-
    K8S_PROFILE_TTY_FD=''
    k8s_profile_error 'unable to save terminal state'
    return 1
  fi
  # Register restoration BEFORE changing mode. Keep ECHO (including ECHONL)
  # disabled across the whole operation, regardless of stderr's TTY status.
  K8S_PROFILE_TTY_ACTIVE=true
  if ! stty -echo -echonl -icanon -iexten -ixon -ixoff -istrip -inlcr -igncr -icrnl -parmrk min 1 time 0 \
    <&"$K8S_PROFILE_TTY_FD" >"$K8S_PROFILE_TMP_DIR/operation-output" 2>"$K8S_PROFILE_TMP_DIR/diagnostics"; then
    k8s_profile_tty_restore || true
    k8s_profile_error 'unable to secure terminal input'
    return 1
  fi
}

k8s_profile_tty_restore() {
  if [ "$K8S_PROFILE_TTY_CURSOR_HIDDEN" = true ]; then
    printf '\033[?25h\n' >&2
    K8S_PROFILE_TTY_CURSOR_HIDDEN=false
  fi
  if [ "$K8S_PROFILE_TTY_ACTIVE" != true ]; then
    return 0
  fi
  if ! stty "$K8S_PROFILE_TTY_STATE" <&"$K8S_PROFILE_TTY_FD" \
    >"$K8S_PROFILE_TMP_DIR/operation-output" 2>"$K8S_PROFILE_TMP_DIR/diagnostics"; then
    k8s_profile_error 'unable to restore terminal state'
    return 1
  fi
  K8S_PROFILE_TTY_ACTIVE=false
  exec {K8S_PROFILE_TTY_FD}<&-
  K8S_PROFILE_TTY_FD=''
  K8S_PROFILE_TTY_STATE=''
}

# Byte-mode, NUL-delimited reads never silently discard NUL or transcode UTF-8.
# stty mode is owned by the caller; no read-by-read ECHO toggling is involved.
k8s_profile_tty_read_key() {
  set +x
  set +a
  local result_var="$1" k8s_profile_key_bytes='' k8s_profile_key_suffix='' read_status
  local LC_ALL=C
  export -n k8s_profile_key_bytes k8s_profile_key_suffix
  # Bash can defer a trapped signal arriving just before a blocking read until
  # the read returns. Bound that wait without toggling terminal mode or treating
  # a timeout as EOF/default consent. This also covers redirected stderr.
  while true; do
    if IFS= read -r -d '' -n 1 -t 0.1 -u "$K8S_PROFILE_TTY_FD" k8s_profile_key_bytes; then
      break
    else
      read_status=$?
      [ "$read_status" -eq 142 ] || return 1
    fi
  done
  [ -n "$k8s_profile_key_bytes" ] || return 2
  if [ "$k8s_profile_key_bytes" = $'\033' ]; then
    while [ "${#k8s_profile_key_bytes}" -lt 32 ]; do
      if ! IFS= read -r -d '' -n 1 -t 0.1 -u "$K8S_PROFILE_TTY_FD" k8s_profile_key_suffix; then
        break
      fi
      [ -n "$k8s_profile_key_suffix" ] || return 2
      k8s_profile_key_bytes+="$k8s_profile_key_suffix"
      case "$k8s_profile_key_suffix" in
      '[' | O) ;;
      [A-Za-z~]) break ;;
      esac
    done
  fi
  printf -v "$result_var" '%s' "$k8s_profile_key_bytes"
}

# Editing positions are byte offsets, but navigation/backspace group UTF-8
# continuation bytes. Invalid encoding remains detectable by the private round
# trip; no locale installation is required for accepted Unicode Tokens.
k8s_profile_tty_previous_position() {
  local result_var="$1" k8s_profile_previous_cursor="$k8s_profile_tty_line_cursor"
  local LC_ALL=C
  if [ "$k8s_profile_previous_cursor" -gt 0 ]; then
    k8s_profile_previous_cursor=$((k8s_profile_previous_cursor - 1))
    while [ "$k8s_profile_previous_cursor" -gt 0 ] && [[ "${k8s_profile_tty_line_buffer:k8s_profile_previous_cursor:1}" == [$'\200'-$'\277'] ]]; do
      k8s_profile_previous_cursor=$((k8s_profile_previous_cursor - 1))
    done
  fi
  printf -v "$result_var" '%s' "$k8s_profile_previous_cursor"
}

k8s_profile_tty_next_position() {
  local result_var="$1" k8s_profile_next_cursor="$k8s_profile_tty_line_cursor"
  local LC_ALL=C
  if [ "$k8s_profile_next_cursor" -lt "${#k8s_profile_tty_line_buffer}" ]; then
    k8s_profile_next_cursor=$((k8s_profile_next_cursor + 1))
    while [ "$k8s_profile_next_cursor" -lt "${#k8s_profile_tty_line_buffer}" ] && [[ "${k8s_profile_tty_line_buffer:k8s_profile_next_cursor:1}" == [$'\200'-$'\277'] ]]; do
      k8s_profile_next_cursor=$((k8s_profile_next_cursor + 1))
    done
  fi
  printf -v "$result_var" '%s' "$k8s_profile_next_cursor"
}

k8s_profile_tty_redraw_line() {
  [ -t 2 ] || return 0
  local label="$1" masked="$2" index right
  local k8s_profile_tty_display='' k8s_profile_tty_left=''
  local LC_ALL=C
  export -n k8s_profile_tty_display k8s_profile_tty_left
  if [ "$masked" = true ]; then
    for ((index = 0; index < ${#k8s_profile_tty_line_buffer}; index++)); do
      if [ "$index" -eq 0 ] || ! [[ "${k8s_profile_tty_line_buffer:index:1}" == [$'\200'-$'\277'] ]]; then
        k8s_profile_tty_display+='*'
        if [ "$index" -lt "$k8s_profile_tty_line_cursor" ]; then
          k8s_profile_tty_left+='*'
        fi
      fi
    done
  else
    k8s_profile_tty_display="$k8s_profile_tty_line_buffer"
    k8s_profile_tty_left="${k8s_profile_tty_line_buffer:0:k8s_profile_tty_line_cursor}"
  fi
  printf '\r\033[2K%s%s' "$label" "$k8s_profile_tty_display" >&2
  right=$((${#k8s_profile_tty_display} - ${#k8s_profile_tty_left}))
  [ "$right" -eq 0 ] || printf '\033[%dD' "$right" >&2
}

k8s_profile_tty_read_line() {
  set +x
  set +a
  local result_var="$1" label="$2" masked="$3" status position
  local k8s_profile_tty_line_buffer='' k8s_profile_tty_line_key='' k8s_profile_tty_line_cursor=0
  local LC_ALL=C
  export -n k8s_profile_tty_line_buffer k8s_profile_tty_line_key
  while true; do
    if k8s_profile_tty_read_key k8s_profile_tty_line_key; then
      :
    else
      status=$?
      return "$status"
    fi
    case "$k8s_profile_tty_line_key" in
    $'\n' | $'\r')
      printf -v "$result_var" '%s' "$k8s_profile_tty_line_buffer"
      return 0
      ;;
    $'\004') return 1 ;; # EOF never accepts a partial line or a default.
    $'\177' | $'\b')
      k8s_profile_tty_previous_position position
      k8s_profile_tty_line_buffer="${k8s_profile_tty_line_buffer:0:position}${k8s_profile_tty_line_buffer:k8s_profile_tty_line_cursor}"
      k8s_profile_tty_line_cursor=$position
      ;;
    $'\033[D' | $'\002') k8s_profile_tty_previous_position k8s_profile_tty_line_cursor ;;
    $'\033[C' | $'\006') k8s_profile_tty_next_position k8s_profile_tty_line_cursor ;;
    $'\033[H' | $'\033OH' | $'\033[1~' | $'\033[7~' | $'\001') k8s_profile_tty_line_cursor=0 ;;
    $'\033[F' | $'\033OF' | $'\033[4~' | $'\033[8~' | $'\005') k8s_profile_tty_line_cursor=${#k8s_profile_tty_line_buffer} ;;
    $'\033[3~')
      k8s_profile_tty_next_position position
      k8s_profile_tty_line_buffer="${k8s_profile_tty_line_buffer:0:k8s_profile_tty_line_cursor}${k8s_profile_tty_line_buffer:position}"
      ;;
    $'\025')
      k8s_profile_tty_line_buffer="${k8s_profile_tty_line_buffer:k8s_profile_tty_line_cursor}"
      k8s_profile_tty_line_cursor=0
      ;;
    $'\013') k8s_profile_tty_line_buffer="${k8s_profile_tty_line_buffer:0:k8s_profile_tty_line_cursor}" ;;
    $'\033'*) continue ;;
    *)
      # All ordinary editable fields have an ASCII contract. Never render
      # unrecognised terminal controls; secret bytes are only ever masked.
      if [ "$masked" != true ] && ! [[ "$k8s_profile_tty_line_key" == [\ -~] ]]; then
        return 3
      fi
      k8s_profile_tty_line_buffer="${k8s_profile_tty_line_buffer:0:k8s_profile_tty_line_cursor}$k8s_profile_tty_line_key${k8s_profile_tty_line_buffer:k8s_profile_tty_line_cursor}"
      k8s_profile_tty_line_cursor=$((k8s_profile_tty_line_cursor + ${#k8s_profile_tty_line_key}))
      ;;
    esac
    k8s_profile_tty_redraw_line "$label" "$masked"
  done
}

k8s_profile_prompt_required() {
  local label="$1" default_value="${2:-}" answer prompt_text status
  while true; do
    prompt_text="$label: "
    if [ -n "$default_value" ]; then
      prompt_text="$label [$default_value]: "
    fi
    if [ -t 0 ]; then k8s_profile_tty_begin || return 1; fi
    printf '%s' "$prompt_text" >&2
    if [ -t 0 ]; then
      if k8s_profile_tty_read_line answer "$prompt_text" false; then status=0; else status=$?; fi
      k8s_profile_tty_restore || return 1
      printf '\n' >&2
    else
      if k8s_profile_read_input_line answer; then status=0; else status=$?; fi
    fi
    if [ "$status" -ne 0 ]; then
      k8s_profile_input_error "$status"
      return 1
    fi
    if [ -z "$answer" ]; then
      answer="$default_value"
    fi
    if ! [[ "$answer" =~ [^[:space:]] ]]; then
      printf 'Value is required.\n' >&2
      continue
    fi
    printf '%s\n' "$answer"
    return 0
  done
}

# Keep the shared numbered/arrow-key UI, but do not let its non-TTY read accept
# a partial line at EOF, discard NUL, apply a default at EOF, or parse an
# overflowing/octal index. Only a completed, bounded index reaches that UI.
k8s_profile_checked_menu_input() {
  local count="$1" answer status
  if k8s_profile_read_input_line answer; then
    :
  else
    status=$?
    k8s_profile_input_error "$status"
    printf 'invalid\n'
    return 1
  fi
  case "$answer" in
  '' | q | Q) printf '%s\n' "$answer" ;;
  *)
    if [[ "$answer" =~ ^[1-9][0-9]*$ ]] && [ "${#answer}" -le "${#count}" ] && [ "$answer" -le "$count" ]; then
      printf '%s\n' "$answer"
    else
      printf 'invalid\n'
    fi
    ;;
  esac
}

k8s_profile_prompt_select_index() {
  if [ -t 0 ] && [ -t 2 ]; then
    k8s_profile_tty_select_index "$@"
  elif [ -t 0 ]; then
    k8s_profile_tty_numbered_index "$@"
  else
    picotools_prompt_select_index "$@" < <(k8s_profile_checked_menu_input "$(($# - 4))")
  fi
}

# Narrow adapter for the shared arrow-key menu's presentation. Checked key
# reads stay in the main shell so its signal/EXIT cleanup always restores mode.
k8s_profile_tty_select_index() {
  local header="$1" default_index="${3:-}" key status index option prefix rendered=false
  local selected_start='' selected_end=''
  shift 4
  local -a options=("$@")
  local count=${#options[@]} selected_index="${default_index:-1}"
  [ "$count" -gt 0 ] || return 1
  if ! [[ "$selected_index" =~ ^[0-9]+$ ]] || [ "$selected_index" -lt 1 ] || [ "$selected_index" -gt "$count" ]; then selected_index=1; fi
  if [ "${TERM:-}" != dumb ]; then
    selected_start=$'\033[1;36m'
    selected_end=$'\033[0m'
  fi
  k8s_profile_tty_begin || return 1
  printf '%s\nUse up/down to choose, Enter to confirm, Esc or q to cancel.\n' "$header" >&2
  K8S_PROFILE_TTY_CURSOR_HIDDEN=true
  printf '\033[?25l' >&2
  while true; do
    if [ "$rendered" = true ]; then printf '\033[%dA' "$count" >&2; fi
    index=1
    for option in "${options[@]}"; do
      prefix='  '
      if [ "$index" -eq "$selected_index" ]; then
        prefix="> $selected_start"
        option+="$selected_end"
      fi
      printf '\033[2K\r%s%s\n' "$prefix" "$option" >&2
      index=$((index + 1))
    done
    rendered=true
    if k8s_profile_tty_read_key key; then
      :
    else
      status=$?
      k8s_profile_tty_restore || return 1
      k8s_profile_input_error "$status"
      return 1
    fi
    case "$key" in
    $'\n' | $'\r')
      k8s_profile_tty_restore || return 1
      printf '%s\n' "$selected_index"
      return 0
      ;;
    q | Q | $'\033' | $'\004')
      k8s_profile_tty_restore || return 1
      return 2
      ;;
    $'\033[A') if [ "$selected_index" -gt 1 ]; then selected_index=$((selected_index - 1)); fi ;;
    $'\033[B') if [ "$selected_index" -lt "$count" ]; then selected_index=$((selected_index + 1)); fi ;;
    esac
  done
}

# A terminal stdin with redirected stderr retains the numbered/non-pretty UI,
# while using exactly the same checked terminal input and restoration boundary.
k8s_profile_tty_numbered_index() {
  local header="$1" prompt="$2" default_index="${3:-}" answer status index=1 option
  shift 4
  printf '%s:\n' "$header" >&2
  for option in "$@"; do
    printf '  %d. %s\n' "$index" "$option" >&2
    index=$((index + 1))
  done
  if [ -n "$default_index" ]; then prompt+=" [$default_index]"; fi
  prompt+=': '
  k8s_profile_tty_begin || return 1
  printf '%s' "$prompt" >&2
  if k8s_profile_tty_read_line answer "$prompt" false; then status=0; else status=$?; fi
  k8s_profile_tty_restore || return 1
  if [ "$status" -ne 0 ]; then
    k8s_profile_input_error "$status"
    return 1
  fi
  case "$answer" in
  q | Q) return 2 ;;
  '') answer="$default_index" ;;
  esac
  if ! [[ "$answer" =~ ^[1-9][0-9]*$ ]] || [ "${#answer}" -gt "${#index}" ] || [ "$answer" -ge "$index" ]; then
    k8s_profile_error 'invalid selection'
    return 1
  fi
  printf '%s\n' "$answer"
}

# The shared yes/no reader intentionally tolerates EOF. Destructive lifecycle
# confirmation instead requires a completed line, even when the answer is yes.
k8s_profile_prompt_confirmation() {
  local label="$1" answer status
  while true; do
    if [ -t 0 ]; then
      k8s_profile_tty_begin || return 1
      printf '%s [y/N]: ' "$label" >&2
      if k8s_profile_tty_read_line answer "$label [y/N]: " false; then status=0; else status=$?; fi
      k8s_profile_tty_restore || return 1
      printf '\n' >&2
    else
      printf '%s [y/N]: ' "$label" >&2
      if k8s_profile_read_input_line answer; then status=0; else status=$?; fi
    fi
    if [ "$status" -ne 0 ]; then
      k8s_profile_input_error "$status"
      return 1
    fi
    case "${answer,,}" in
    y | yes)
      printf 'yes\n'
      return 0
      ;;
    '' | n | no)
      printf 'no\n'
      return 0
      ;;
    *) printf 'Please answer yes or no.\n' >&2 ;;
    esac
  done
}

k8s_profile_prompt_delete_confirmation() {
  k8s_profile_prompt_confirmation "$1"
}

k8s_profile_validate_name() {
  if ! [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]; then
    k8s_profile_error 'profile name must match [A-Za-z0-9._-]+'
    return 1
  fi
}

# Kubernetes namespace names are DNS-1123 labels. Offline validation only;
# existence and RBAC are cluster-side concerns this tool never contacts.
k8s_profile_validate_namespace() {
  if ! [[ "$1" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then
    k8s_profile_error 'Namespace must be a DNS-1123 label: lowercase alphanumeric and "-" only, at most 63 characters'
    return 1
  fi
}

k8s_profile_valid_ipv4() {
  local address="$1" part
  local -a parts=()
  IFS=. read -r -a parts <<<"$address"
  [ "${#parts[@]}" -eq 4 ] && [[ "$address" != *. ]] || return 1
  for part in "${parts[@]}"; do
    [[ "$part" =~ ^[0-9]{1,3}$ ]] && [ "$((10#$part))" -le 255 ] || return 1
  done
}

k8s_profile_valid_ipv6() {
  local address="$1" original="$1" remainder part index count=0 compressed=false
  local -a parts=()
  [[ "$address" != *:::* ]] || return 1
  if [[ "$address" == *::* ]]; then
    compressed=true
    [[ "$address" != :[^:]* && "$address" != *[^:]: ]] || return 1
    remainder=${address#*::}
    [[ "$remainder" != *::* ]] || return 1
    address="${address/::/:}"
    address="${address#:}"
    address="${address%:}"
  else
    [[ "$address" != :* && "$address" != *: ]] || return 1
  fi
  IFS=: read -r -a parts <<<"$address"
  for index in "${!parts[@]}"; do
    part=${parts[$index]}
    if [[ "$part" == *.* ]]; then
      [ "$index" -eq "$((${#parts[@]} - 1))" ] && [[ "$original" == *"$part" ]] && k8s_profile_valid_ipv4 "$part" || return 1
      count=$((count + 2))
    else
      [[ "$part" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
      count=$((count + 1))
    fi
  done
  if [ "$compressed" = true ]; then
    [ "$count" -lt 8 ]
  else
    [ "$count" -eq 8 ]
  fi
}

k8s_profile_validate_server() {
  local server="$1" authority host port='' path label encoded
  local -a labels=()
  local valid=true
  if [[ "$server" != https://* || "$server" =~ [[:space:][:cntrl:]] || "$server" == *\\* || "$server" == *\?* || "$server" == *\#* ]]; then
    valid=false
  fi
  authority=${server#https://}
  authority=${authority%%/*}
  path=${server#https://"$authority"}
  if [[ "$authority" =~ ^\[([0-9A-Fa-f:.]+)\](:([0-9]+))?$ ]]; then
    host=${BASH_REMATCH[1]}
    port=${BASH_REMATCH[3]:-}
    k8s_profile_valid_ipv6 "$host" || valid=false
  elif [[ "$authority" =~ ^([A-Za-z0-9.-]+)(:([0-9]+))?$ ]]; then
    host=${BASH_REMATCH[1]}
    port=${BASH_REMATCH[3]:-}
    if [[ "$host" =~ ^[0-9.]+$ && "$host" == *.* ]]; then
      k8s_profile_valid_ipv4 "$host" || valid=false
    else
      host=${host%.}
      [ -n "$host" ] && [ "${#host}" -le 253 ] && [[ "$host" != *..* && "$host" != *. ]] || valid=false
      IFS=. read -r -a labels <<<"$host"
      for label in "${labels[@]}"; do
        if ! [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]]; then
          valid=false
        fi
      done
    fi
  else
    valid=false
  fi
  if [ -n "$port" ]; then
    if [ "${#port}" -gt 5 ] || [ "$((10#$port))" -lt 1 ] || [ "$((10#$port))" -gt 65535 ]; then
      valid=false
    fi
  fi
  # RFC 3986 path characters; percent escapes must not hide controls/whitespace.
  if [[ "$path" =~ [^A-Za-z0-9._~!\$\&\'\(\)\*+,\;=:@%/-] ]]; then
    valid=false
  fi
  encoded="$path"
  while [[ "$encoded" == *%* ]]; do
    encoded=${encoded#*%}
    if ! [[ "$encoded" =~ ^[0-9A-Fa-f]{2} ]] || [[ "${encoded:0:2}" =~ ^(0[0-9A-Fa-f]|1[0-9A-Fa-f]|20|7[fF])$ ]]; then
      valid=false
      break
    fi
    encoded=${encoded:2}
  done
  if [ "$valid" != true ]; then
    k8s_profile_error 'Server must be a valid HTTPS API URL without userinfo, query, fragment, whitespace, or controls'
    return 1
  fi
}

k8s_profile_validate_token_file() {
  local input_file="$1"
  # jq's rawfile loader replaces invalid UTF-8. Compare a private JSON round
  # trip byte-for-byte before using that loader for any credential mutation.
  # shellcheck disable=SC2016 # jq reads the Token only from the private file.
  k8s_profile_jq "$K8S_PROFILE_TMP_DIR/token-encoded.json" 'unable to validate private Token input' \
    -n --ascii-output --rawfile token "$input_file" '$token' || return 1
  k8s_profile_jq "$K8S_PROFILE_TMP_DIR/token-decoded" 'unable to validate private Token input' \
    -j '.' "$K8S_PROFILE_TMP_DIR/token-encoded.json" || return 1
  if ! cmp -s -- "$input_file" "$K8S_PROFILE_TMP_DIR/token-decoded" 2>"$K8S_PROFILE_TMP_DIR/diagnostics"; then
    k8s_profile_error 'Token must be valid UTF-8'
    return 1
  fi
  k8s_profile_jq "$K8S_PROFILE_TMP_DIR/token-policy-check" 'Token must be nonblank and contain no whitespace or controls' \
    -e 'length > 0 and (test("[\\s\\p{Cc}]") | not)' "$K8S_PROFILE_TMP_DIR/token-encoded.json"
}

k8s_profile_read_token_file() {
  set +x
  set +a
  local result_var="$1" k8s_profile_token_value='' input_file status
  # A same-named inherited variable must not leave the local secret exported.
  export -n k8s_profile_token_value
  while true; do
    printf 'Token: ' >&2
    if [ -t 0 ]; then
      if k8s_profile_tty_read_line k8s_profile_token_value 'Token: ' true; then
        status=0
      else
        status=$?
      fi
    else
      if k8s_profile_read_input_line k8s_profile_token_value; then
        status=0
      else
        status=$?
      fi
    fi
    printf '\n' >&2
    if [ "$status" -ne 0 ]; then
      unset k8s_profile_token_value
      k8s_profile_input_error "$status"
      return 1
    fi
    if [ -n "$k8s_profile_token_value" ]; then
      break
    fi
    printf 'Value is required.\n' >&2
  done
  if ! [[ "$k8s_profile_token_value" =~ [^[:space:]] ]] || [[ "$k8s_profile_token_value" =~ [[:space:][:cntrl:]] ]]; then
    unset k8s_profile_token_value
    k8s_profile_error 'Token must be nonblank and contain no whitespace or controls'
    return 1
  fi
  input_file="$K8S_PROFILE_TMP_DIR/token-input"
  if ! { : >"$input_file"; } 2>"$K8S_PROFILE_TMP_DIR/diagnostics"; then
    unset k8s_profile_token_value
    k8s_profile_error 'unable to prepare private Token input'
    return 1
  fi
  if ! chmod 600 -- "$input_file" >"$K8S_PROFILE_TMP_DIR/operation-output" 2>"$K8S_PROFILE_TMP_DIR/diagnostics"; then
    unset k8s_profile_token_value
    rm -f -- "$input_file" >"$K8S_PROFILE_TMP_DIR/operation-output" 2>"$K8S_PROFILE_TMP_DIR/diagnostics" || true
    k8s_profile_error 'unable to secure Token input'
    return 1
  fi
  if ! { builtin printf '%s' "$k8s_profile_token_value" >"$input_file"; } 2>"$K8S_PROFILE_TMP_DIR/diagnostics"; then
    unset k8s_profile_token_value
    rm -f -- "$input_file" >"$K8S_PROFILE_TMP_DIR/operation-output" 2>"$K8S_PROFILE_TMP_DIR/diagnostics" || true
    k8s_profile_error 'unable to write private Token input'
    return 1
  fi
  unset k8s_profile_token_value
  if ! k8s_profile_validate_token_file "$input_file"; then
    rm -f -- "$input_file" >"$K8S_PROFILE_TMP_DIR/operation-output" 2>"$K8S_PROFILE_TMP_DIR/diagnostics" || true
    return 1
  fi
  printf -v "$result_var" '%s' "$input_file"
}

k8s_profile_prompt_token_file() {
  set +x
  set +a
  local status
  k8s_profile_tty_begin || return 1
  if k8s_profile_read_token_file "$1"; then status=0; else status=$?; fi
  # Token and editing locals have gone out of scope before restoring ECHO.
  k8s_profile_tty_restore || return 1
  return "$status"
}
