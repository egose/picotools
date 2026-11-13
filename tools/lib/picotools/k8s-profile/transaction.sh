#!/usr/bin/env bash
# shellcheck disable=SC2016 # Recovery manifest programs use jq variables.

if [ "${PICOTOOLS_K8S_PROFILE_TRANSACTION_SH_LOADED:-0}" -eq 1 ]; then
  return 0
fi
PICOTOOLS_K8S_PROFILE_TRANSACTION_SH_LOADED=1

K8S_PROFILE_TX_WRITE_SET=()
K8S_PROFILE_TX_CANDIDATES=()
K8S_PROFILE_TX_ATTEMPTED=()
K8S_PROFILE_TX_PUBLISH_KEYS=()
K8S_PROFILE_TX_PUBLISHED_FINGERPRINTS=()
K8S_PROFILE_TX_VALIDATED_FINGERPRINTS=()
K8S_PROFILE_TX_LOCK_PATHS=()
K8S_PROFILE_TX_LOCK_FINGERPRINTS=()
K8S_PROFILE_TX_LOCK_KEYS=()
K8S_PROFILE_TX_ACTIVE=false

k8s_profile_file_fingerprint() {
  local path="$1" before after digest links
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    printf 'missing\n'
    return 0
  fi
  if [ -L "$path" ] || [ ! -f "$path" ]; then
    k8s_profile_error 'unsafe kubeconfig path (symbolic link or nonregular file)'
    return 1
  fi
  links=$(stat --printf='%h' -- "$path" 2>"$K8S_PROFILE_TMP_DIR/diagnostics") || return 1
  if [ "$links" != 1 ]; then
    k8s_profile_error 'unsafe kubeconfig path (hard-linked file)'
    return 1
  fi
  before=$(stat --printf='%d:%i:%h:%u:%f:%s:%y:%z' -- "$path" 2>"$K8S_PROFILE_TMP_DIR/diagnostics") || return 1
  if ! digest=$(sha256sum <"$path" 2>"$K8S_PROFILE_TMP_DIR/diagnostics"); then
    k8s_profile_error 'unable to fingerprint kubeconfig'
    return 1
  fi
  after=$(stat --printf='%d:%i:%h:%u:%f:%s:%y:%z' -- "$path" 2>"$K8S_PROFILE_TMP_DIR/diagnostics") || return 1
  if [ "$before" != "$after" ]; then
    k8s_profile_error 'kubeconfig changed while being checked; retry the command'
    return 1
  fi
  printf '%s:%s\n' "$before" "${digest%% *}"
}

# The pre-rename ownership key omits ctime/nlink, which change on rename/link.
# Once published, recovery requires the complete post-publication fingerprint.
k8s_profile_file_publish_key() {
  local path="$1" before after digest
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  before=$(stat --printf='%d:%i:%u:%f:%s:%y' -- "$path" 2>"$K8S_PROFILE_TMP_DIR/diagnostics") || return 1
  digest=$(sha256sum <"$path" 2>"$K8S_PROFILE_TMP_DIR/diagnostics") || return 1
  after=$(stat --printf='%d:%i:%u:%f:%s:%y' -- "$path" 2>"$K8S_PROFILE_TMP_DIR/diagnostics") || return 1
  [ "$before" = "$after" ] || return 1
  printf '%s:%s\n' "$before" "${digest%% *}"
}

k8s_profile_check_ancestors() {
  local path="$1" writing="$2" description="${3:-kubeconfig}" parent="${1%/*}" current=/ component owner mode
  local diagnostics="${K8S_PROFILE_TMP_DIR:+$K8S_PROFILE_TMP_DIR/diagnostics}"
  local -a components=()
  if [[ "$path" =~ [[:cntrl:]] ]]; then
    k8s_profile_error 'unsafe kubeconfig path (control characters)'
    return 1
  fi
  parent=${parent:-/}
  diagnostics=${diagnostics:-/dev/null}
  IFS=/ read -r -a components <<<"$parent"
  components=(/ "${components[@]}")
  for component in "${components[@]}"; do
    case "$component" in
    /) current=/ ;;
    '') continue ;;
    . | ..)
      # Native traversal requires the preceding directory to exist. Creating
      # it could expose an existing hidden target, and EXIT cleanup could make
      # a successfully saved lexical path inaccessible again.
      if [ ! -d "$current" ]; then
        k8s_profile_error "unsafe $description directory (missing traversal ancestor)"
        return 1
      fi
      current="${current%/}/$component"
      ;;
    *) current="${current%/}/$component" ;;
    esac
    if [ -L "$current" ] || { [ -e "$current" ] && [ ! -d "$current" ]; }; then
      k8s_profile_error "unsafe $description directory (symbolic link or nondirectory)"
      return 1
    fi
    if [ ! -d "$current" ]; then
      continue
    fi
    if [ "$writing" = true ]; then
      owner=$(stat --printf='%u' -- "$current" 2>"$diagnostics") || return 1
      mode=$(stat --printf='%a' -- "$current" 2>"$diagnostics") || return 1
      if [ "$owner" != "$UID" ] && [ "$owner" != 0 ]; then
        k8s_profile_error "unsafe $description directory (foreign owner)"
        return 1
      fi
      # Root-owned sticky ancestors such as /tmp are safe above a private,
      # user-owned destination directory; nonsticky writable ancestors are not.
      if [ "$((8#$mode & 0022))" -ne 0 ] && { [ "$owner" != 0 ] || [ "$((8#$mode & 01000))" -eq 0 ]; }; then
        k8s_profile_error "unsafe $description directory (group/world writable)"
        return 1
      fi
    fi
  done
}

k8s_profile_parent_state() {
  local path="$1" parent="${1%/*}" current=/ component state=''
  local -a components=()
  k8s_profile_check_ancestors "$path" false || return 1
  parent=${parent:-/}
  IFS=/ read -r -a components <<<"$parent"
  components=(/ "${components[@]}")
  for component in "${components[@]}"; do
    case "$component" in
    /) current=/ ;;
    '') continue ;;
    *) current="${current%/}/$component" ;;
    esac
    if [ -d "$current" ]; then
      state+="$(stat --printf='%d:%i:%u:%f' -- "$current" 2>"$K8S_PROFILE_TMP_DIR/diagnostics")|" || return 1
    else
      state+='missing|'
    fi
  done
  printf '%s\n' "$state"
}

k8s_profile_preflight_write() {
  local path="$1" parent="${1%/*}" owner mode
  k8s_profile_check_ancestors "$path" true || return 1
  k8s_profile_file_fingerprint "$path" >/dev/null || return 1
  if [ -e "$path" ]; then
    owner=$(stat --printf='%u' -- "$path" 2>"$K8S_PROFILE_TMP_DIR/diagnostics") || return 1
    if [ "$owner" != "$UID" ]; then
      k8s_profile_error 'unsafe kubeconfig target (foreign owner)'
      return 1
    fi
  fi
  parent=${parent:-/}
  while [ ! -d "$parent" ]; do
    parent=${parent%/*}
    parent=${parent:-/}
  done
  owner=$(stat --printf='%u' -- "$parent" 2>"$K8S_PROFILE_TMP_DIR/diagnostics") || return 1
  mode=$(stat --printf='%a' -- "$parent" 2>"$K8S_PROFILE_TMP_DIR/diagnostics") || return 1
  if [ "$owner" != "$UID" ] || [ "$((8#$mode & 0022))" -ne 0 ] || [ "$((8#$mode & 0300))" -ne 192 ]; then
    k8s_profile_error 'kubeconfig parent must be user-owned, writable, searchable, and not group/world writable'
    return 1
  fi
}

k8s_profile_ensure_parent() {
  local path="$1" parent="${1%/*}" current=/ component key
  local -a components=()
  parent=${parent:-/}
  IFS=/ read -r -a components <<<"$parent"
  for component in "${components[@]}"; do
    [ -n "$component" ] || continue
    current="${current%/}/$component"
    if [ -d "$current" ]; then
      continue
    fi
    if ! mkdir -m 700 -- "$current" >"$K8S_PROFILE_TMP_DIR/operation-output" 2>"$K8S_PROFILE_TMP_DIR/diagnostics"; then
      k8s_profile_error 'unable to create a safe kubeconfig directory'
      return 1
    fi
    K8S_PROFILE_CREATED_DIRS+=("$current")
    key=$(stat --printf='%d:%i' -- "$current" 2>"$K8S_PROFILE_TMP_DIR/diagnostics") || return 1
    K8S_PROFILE_CREATED_DIR_KEYS+=("$key")
  done
  k8s_profile_preflight_write "$path"
}

# Call add_file in desired publication order (delete can clear low-precedence
# current references first). Locks are acquired independently in path order.
k8s_profile_tx_add_file() {
  local index="$1" existing
  if ! [[ "$index" =~ ^[0-9]+$ ]] || [ "$index" -ge "${#K8S_PROFILE_CHAIN_PATHS[@]}" ]; then
    k8s_profile_error 'invalid transaction file index'
    return 1
  fi
  for existing in "${K8S_PROFILE_TX_WRITE_SET[@]}"; do
    [ "$existing" != "$index" ] || return 0
  done
  K8S_PROFILE_TX_WRITE_SET+=("$index")
}

k8s_profile_tx_prepare() {
  local index path dir candidate lock source fingerprint key position previous
  local LC_ALL=C
  local -a lock_order=()
  k8s_profile_recheck_chain || return 1
  [ "${#K8S_PROFILE_TX_WRITE_SET[@]}" -gt 0 ] || return 1
  # Preflight the entire write-set before creating any directory or lock.
  for index in "${K8S_PROFILE_TX_WRITE_SET[@]}"; do
    k8s_profile_preflight_write "${K8S_PROFILE_CHAIN_PATHS[$index]}" || return 1
  done
  for index in "${K8S_PROFILE_TX_WRITE_SET[@]}"; do
    k8s_profile_ensure_parent "${K8S_PROFILE_CHAIN_PATHS[$index]}" || return 1
  done
  # Only our directory creation changes the recorded ancestor identity state.
  for index in "${!K8S_PROFILE_CHAIN_PATHS[@]}"; do
    fingerprint=$(k8s_profile_file_fingerprint "${K8S_PROFILE_CHAIN_PATHS[$index]}") || return 1
    if [ "$fingerprint" != "${K8S_PROFILE_CHAIN_FINGERPRINTS[$index]}" ]; then
      k8s_profile_error 'kubeconfig changed before staging; retry the command'
      return 1
    fi
    K8S_PROFILE_CHAIN_PARENT_STATES[index]=$(k8s_profile_parent_state "${K8S_PROFILE_CHAIN_PATHS[$index]}") || return 1
  done
  for index in "${K8S_PROFILE_TX_WRITE_SET[@]}"; do
    position=${#lock_order[@]}
    while [ "$position" -gt 0 ]; do
      previous=${lock_order[$((position - 1))]}
      [[ "${K8S_PROFILE_CHAIN_PATHS[$previous]}" > "${K8S_PROFILE_CHAIN_PATHS[$index]}" ]] || break
      lock_order[position]=$previous
      position=$((position - 1))
    done
    lock_order[position]=$index
  done
  for index in "${lock_order[@]}"; do
    path=${K8S_PROFILE_CHAIN_PATHS[$index]}
    lock="$path.lock"
    source="$K8S_PROFILE_TMP_DIR/lock-$index"
    printf '%s\n' "$$" >"$source"
    key=$(k8s_profile_file_publish_key "$source") || return 1
    # Register before link so handled signals cannot strand our just-created lock.
    K8S_PROFILE_TX_LOCK_PATHS+=("$lock")
    K8S_PROFILE_TX_LOCK_KEYS+=("$key")
    K8S_PROFILE_TX_LOCK_FINGERPRINTS+=('')
    # link(2) is exclusive even if a FIFO/symlink/directory appears concurrently.
    if ! ln -T -- "$source" "$lock" >"$K8S_PROFILE_TMP_DIR/operation-output" 2>"$K8S_PROFILE_TMP_DIR/diagnostics"; then
      k8s_profile_error 'kubeconfig lock is unavailable; another writer may be active'
      return 1
    fi
    if ! rm -f -- "$source" >"$K8S_PROFILE_TMP_DIR/operation-output" 2>"$K8S_PROFILE_TMP_DIR/diagnostics"; then
      k8s_profile_error 'unable to finish acquiring kubeconfig lock'
      return 1
    fi
    fingerprint=$(k8s_profile_file_fingerprint "$lock") || return 1
    K8S_PROFILE_TX_LOCK_FINGERPRINTS[${#K8S_PROFILE_TX_LOCK_PATHS[@]} - 1]=$fingerprint
  done
  k8s_profile_recheck_chain || return 1
  for index in "${K8S_PROFILE_TX_WRITE_SET[@]}"; do
    path=${K8S_PROFILE_CHAIN_PATHS[$index]}
    dir=${path%/*}
    dir=${dir:-/}
    if ! candidate=$(mktemp "$dir/.k8s-profile.stage.XXXXXX" 2>"$K8S_PROFILE_TMP_DIR/diagnostics"); then
      k8s_profile_error 'unable to stage kubeconfig in its destination directory'
      return 1
    fi
    K8S_PROFILE_STAGE_FILES+=("$candidate")
    K8S_PROFILE_TX_CANDIDATES[index]=$candidate
    if ! cp -- "${K8S_PROFILE_CHAIN_RAW[$index]}" "$candidate" >"$K8S_PROFILE_TMP_DIR/operation-output" 2>"$K8S_PROFILE_TMP_DIR/diagnostics" ||
      ! chmod 600 -- "$candidate" >"$K8S_PROFILE_TMP_DIR/operation-output" 2>"$K8S_PROFILE_TMP_DIR/diagnostics"; then
      k8s_profile_error 'unable to prepare private kubeconfig candidate'
      return 1
    fi
    k8s_profile_write_config "$candidate" 'unable to serialize a physical kubeconfig candidate' '.' "${K8S_PROFILE_CHAIN_RAW[$index]}" || return 1
  done
  k8s_profile_recheck_chain
}

k8s_profile_tx_release_locks() {
  local index lock fingerprint
  for index in "${!K8S_PROFILE_TX_LOCK_PATHS[@]}"; do
    lock=${K8S_PROFILE_TX_LOCK_PATHS[$index]}
    # Never remove a lock which was present before us or has been replaced.
    if [ -n "${K8S_PROFILE_TX_LOCK_FINGERPRINTS[$index]:-}" ]; then
      fingerprint=$(k8s_profile_file_fingerprint "$lock" 2>/dev/null) || continue
      if [ "$fingerprint" = "${K8S_PROFILE_TX_LOCK_FINGERPRINTS[$index]}" ]; then
        rm -f -- "$lock" >/dev/null 2>&1 || true
      fi
    else
      fingerprint=$(k8s_profile_file_publish_key "$lock") || continue
      if [ "$fingerprint" = "${K8S_PROFILE_TX_LOCK_KEYS[$index]}" ]; then
        rm -f -- "$lock" >/dev/null 2>&1 || true
      fi
    fi
  done
}

k8s_profile_tx_assert_locks() {
  local index fingerprint
  for index in "${!K8S_PROFILE_TX_LOCK_PATHS[@]}"; do
    fingerprint=$(k8s_profile_file_fingerprint "${K8S_PROFILE_TX_LOCK_PATHS[$index]}" 2>/dev/null) || fingerprint=unsafe
    if [ "$fingerprint" != "${K8S_PROFILE_TX_LOCK_FINGERPRINTS[$index]}" ]; then
      k8s_profile_error 'kubeconfig lock changed during the transaction'
      return 1
    fi
  done
}

k8s_profile_tx_recheck_expected() {
  local index fingerprint expected parents
  k8s_profile_tx_assert_locks || return 1
  for index in "${!K8S_PROFILE_CHAIN_PATHS[@]}"; do
    fingerprint=$(k8s_profile_file_fingerprint "${K8S_PROFILE_CHAIN_PATHS[$index]}") || return 1
    expected="${K8S_PROFILE_TX_PUBLISHED_FINGERPRINTS[$index]:-${K8S_PROFILE_CHAIN_FINGERPRINTS[$index]}}"
    parents=$(k8s_profile_parent_state "${K8S_PROFILE_CHAIN_PATHS[$index]}") || return 1
    if [ "$fingerprint" != "$expected" ] || [ "$parents" != "${K8S_PROFILE_CHAIN_PARENT_STATES[$index]}" ]; then
      k8s_profile_error 'kubeconfig changed during publication'
      return 1
    fi
  done
}

k8s_profile_tx_live_is_ours() {
  local index="$1" actual
  if [ -n "${K8S_PROFILE_TX_PUBLISHED_FINGERPRINTS[$index]:-}" ]; then
    actual=$(k8s_profile_file_fingerprint "${K8S_PROFILE_CHAIN_PATHS[$index]}" 2>/dev/null) || return 1
    [ "$actual" = "${K8S_PROFILE_TX_PUBLISHED_FINGERPRINTS[$index]}" ]
  else
    actual=$(k8s_profile_file_publish_key "${K8S_PROFILE_CHAIN_PATHS[$index]}") || return 1
    [ "$actual" = "${K8S_PROFILE_TX_PUBLISH_KEYS[$index]:-}" ]
  fi
}

k8s_profile_tx_recovery_manifest() {
  local index item
  local -a files=()
  # Builtin-only fallback survives a missing/failing jq during recovery. All
  # values are paths/booleans, shell-escaped, never configuration contents.
  {
    builtin printf 'k8s-profile recovery manifest version 1\nInspect live edits before manual recovery; do not overwrite newer state.\n'
    for index in "${K8S_PROFILE_TX_ATTEMPTED[@]}"; do
      builtin printf 'path=%q\nbackup=%q\noriginal_present=%s\n\n' \
        "${K8S_PROFILE_CHAIN_PATHS[$index]}" "${K8S_PROFILE_CHAIN_BACKUPS[$index]}" "${K8S_PROFILE_CHAIN_EXISTED[$index]}"
    done
  } >"$K8S_PROFILE_TMP_DIR/recovery.txt" || return 1
  for index in "${K8S_PROFILE_TX_ATTEMPTED[@]}"; do
    item="$K8S_PROFILE_TMP_DIR/recovery-file-$index.json"
    k8s_profile_jq "$item" 'unable to write recovery manifest' -n \
      --arg path "${K8S_PROFILE_CHAIN_PATHS[$index]}" --arg backup "${K8S_PROFILE_CHAIN_BACKUPS[$index]}" \
      --argjson existed "${K8S_PROFILE_CHAIN_EXISTED[$index]}" \
      '{path:$path,backup:$backup,existed:$existed}' || return 1
    files+=("$item")
  done
  k8s_profile_jq "$K8S_PROFILE_TMP_DIR/recovery.json" 'unable to write recovery manifest' -s \
    '{version:1,files:.,note:"Private backups; inspect live changes before manual recovery. No automatic overwrite of newer state."}' "${files[@]}" || {
    rm -f -- "$K8S_PROFILE_TMP_DIR/recovery.json" >"$K8S_PROFILE_TMP_DIR/operation-output" 2>"$K8S_PROFILE_TMP_DIR/diagnostics" || true
    return 1
  }
}

k8s_profile_tx_rollback() {
  local position index path current restore dir backup_digest restored_digest complete=true
  trap '' HUP INT TERM
  # Recovery must continue after one file cannot be restored.
  for ((position = ${#K8S_PROFILE_TX_ATTEMPTED[@]} - 1; position >= 0; position--)); do
    index=${K8S_PROFILE_TX_ATTEMPTED[$position]}
    path=${K8S_PROFILE_CHAIN_PATHS[$index]}
    current=$(k8s_profile_file_fingerprint "$path" 2>/dev/null) || current=unsafe
    if [ "$current" = "${K8S_PROFILE_CHAIN_FINGERPRINTS[$index]}" ]; then
      continue
    fi
    if ! k8s_profile_tx_live_is_ours "$index"; then
      complete=false
      continue
    fi
    if [ "${K8S_PROFILE_CHAIN_EXISTED[$index]}" = false ]; then
      if ! k8s_profile_tx_live_is_ours "$index" || ! rm -f -- "$path" >"$K8S_PROFILE_TMP_DIR/operation-output" 2>"$K8S_PROFILE_TMP_DIR/diagnostics" || [ -e "$path" ] || [ -L "$path" ]; then
        complete=false
      fi
    else
      dir=${path%/*}
      dir=${dir:-/}
      if ! k8s_profile_preflight_write "$path" || ! restore=$(mktemp "$dir/.k8s-profile.restore.XXXXXX" 2>"$K8S_PROFILE_TMP_DIR/diagnostics"); then
        complete=false
        continue
      fi
      K8S_PROFILE_STAGE_FILES+=("$restore")
      if ! cp -- "${K8S_PROFILE_CHAIN_BACKUPS[$index]}" "$restore" >"$K8S_PROFILE_TMP_DIR/operation-output" 2>"$K8S_PROFILE_TMP_DIR/diagnostics" ||
        ! chmod 600 -- "$restore" >"$K8S_PROFILE_TMP_DIR/operation-output" 2>"$K8S_PROFILE_TMP_DIR/diagnostics" ||
        ! k8s_profile_tx_live_is_ours "$index" ||
        ! mv -fT -- "$restore" "$path" >"$K8S_PROFILE_TMP_DIR/operation-output" 2>"$K8S_PROFILE_TMP_DIR/diagnostics"; then
        complete=false
      else
        backup_digest=$(sha256sum <"${K8S_PROFILE_CHAIN_BACKUPS[$index]}" 2>"$K8S_PROFILE_TMP_DIR/diagnostics") || backup_digest='backup-error'
        restored_digest=$(sha256sum <"$path" 2>"$K8S_PROFILE_TMP_DIR/diagnostics") || restored_digest='restore-error'
        if [ "$backup_digest" != "$restored_digest" ]; then
          complete=false
        fi
      fi
    fi
  done
  # shellcheck disable=SC2034 # Consumed by common.sh's EXIT cleanup.
  K8S_PROFILE_TX_ACTIVE=false
  if [ "$complete" != true ]; then
    # shellcheck disable=SC2034 # Consumed by common.sh's EXIT cleanup.
    K8S_PROFILE_RETAIN_RECOVERY=true
    k8s_profile_tx_recovery_manifest || true
    k8s_profile_error 'recovery incomplete; newer or unsafe live state was preserved'
    printf 'Private backups and recovery manifest retained at %q\n' "$K8S_PROFILE_TMP_DIR" >&2
    return 1
  fi
}

k8s_profile_tx_abort() {
  k8s_profile_error 'unable to publish the complete kubeconfig transaction'
  if k8s_profile_tx_rollback; then
    printf 'Previous configuration restored.\n' >&2
  fi
  return 1
}

k8s_profile_preflight_candidate() {
  local path="$1" owner mode
  k8s_profile_file_fingerprint "$path" >/dev/null || return 1
  owner=$(stat --printf='%u' -- "$path" 2>"$K8S_PROFILE_TMP_DIR/diagnostics") || return 1
  mode=$(stat --printf='%a' -- "$path" 2>"$K8S_PROFILE_TMP_DIR/diagnostics") || return 1
  if [ "$owner" != "$UID" ] || [ "$mode" != 600 ]; then
    k8s_profile_error 'kubeconfig candidate must remain user-owned and mode 0600'
    return 1
  fi
}

# Optional verifier receives a private merged nonraw JSON path, both before and
# after publication. It must emit only controlled errors, never raw diagnostics.
k8s_profile_tx_commit() {
  local verifier="${1:-k8s_profile_validate_config_json}" index candidate path key fingerprint before
  k8s_profile_recheck_chain || return 1
  for index in "${K8S_PROFILE_TX_WRITE_SET[@]}"; do
    candidate=${K8S_PROFILE_TX_CANDIDATES[$index]}
    k8s_profile_preflight_candidate "$candidate" || return 1
    before=$(k8s_profile_file_fingerprint "$candidate") || return 1
    k8s_profile_kubectl "$K8S_PROFILE_TMP_DIR/validated-$index.json" 'staged kubeconfig file is invalid' \
      "--kubeconfig=$candidate" config view --raw --merge=false -o json || return 1
    k8s_profile_validate_config_json "$K8S_PROFILE_TMP_DIR/validated-$index.json" || return 1
    k8s_profile_preflight_candidate "$candidate" || return 1
    fingerprint=$(k8s_profile_file_fingerprint "$candidate") || return 1
    if [ "$before" != "$fingerprint" ]; then
      k8s_profile_error 'kubeconfig candidate changed during validation'
      return 1
    fi
    K8S_PROFILE_TX_VALIDATED_FINGERPRINTS[index]=$fingerprint
  done
  k8s_profile_read_substituted_chain "$K8S_PROFILE_TMP_DIR/staged-chain.json" || return 1
  k8s_profile_validate_config_json "$K8S_PROFILE_TMP_DIR/staged-chain.json" || return 1
  "$verifier" "$K8S_PROFILE_TMP_DIR/staged-chain.json" || return 1
  k8s_profile_recheck_chain || return 1
  k8s_profile_tx_assert_locks || return 1
  K8S_PROFILE_TX_ACTIVE=true
  for index in "${K8S_PROFILE_TX_WRITE_SET[@]}"; do
    path=${K8S_PROFILE_CHAIN_PATHS[$index]}
    candidate=${K8S_PROFILE_TX_CANDIDATES[$index]}
    if ! k8s_profile_tx_recheck_expected || ! k8s_profile_preflight_write "$path"; then
      k8s_profile_tx_abort
      return 1
    fi
    fingerprint=$(k8s_profile_file_fingerprint "$candidate") || {
      k8s_profile_tx_abort
      return 1
    }
    if [ "$fingerprint" != "${K8S_PROFILE_TX_VALIDATED_FINGERPRINTS[$index]}" ]; then
      k8s_profile_error 'kubeconfig candidate changed after validation'
      k8s_profile_tx_abort
      return 1
    fi
    key=$(k8s_profile_file_publish_key "$candidate") || {
      k8s_profile_tx_abort
      return 1
    }
    K8S_PROFILE_TX_PUBLISH_KEYS[index]=$key
    # Record the attempt before invoking an external command so handled signals
    # between rename and the following Bash assignment still recover safely.
    K8S_PROFILE_TX_ATTEMPTED+=("$index")
    if [ "${K8S_PROFILE_CHAIN_EXISTED[$index]}" = true ]; then
      if ! mv -fT -- "$candidate" "$path" >"$K8S_PROFILE_TMP_DIR/operation-output" 2>"$K8S_PROFILE_TMP_DIR/diagnostics"; then
        k8s_profile_tx_abort
        return 1
      fi
    else
      if ! ln -T -- "$candidate" "$path" >"$K8S_PROFILE_TMP_DIR/operation-output" 2>"$K8S_PROFILE_TMP_DIR/diagnostics" ||
        ! rm -f -- "$candidate" >"$K8S_PROFILE_TMP_DIR/operation-output" 2>"$K8S_PROFILE_TMP_DIR/diagnostics"; then
        k8s_profile_tx_abort
        return 1
      fi
    fi
    if ! fingerprint=$(k8s_profile_file_fingerprint "$path") || ! k8s_profile_tx_live_is_ours "$index"; then
      k8s_profile_tx_abort
      return 1
    fi
    K8S_PROFILE_TX_PUBLISHED_FINGERPRINTS[index]=$fingerprint
  done
  if ! k8s_profile_tx_recheck_expected ||
    ! k8s_profile_kubectl "$K8S_PROFILE_TMP_DIR/published-chain.json" 'unable to verify published kubeconfig' config view -o json ||
    ! k8s_profile_validate_config_json "$K8S_PROFILE_TMP_DIR/published-chain.json" ||
    ! "$verifier" "$K8S_PROFILE_TMP_DIR/published-chain.json" ||
    ! k8s_profile_tx_recheck_expected; then
    k8s_profile_tx_abort
    return 1
  fi
  # shellcheck disable=SC2034 # Consumed by common.sh's EXIT cleanup.
  K8S_PROFILE_TX_ACTIVE=false
  debug_log "Published ${#K8S_PROFILE_TX_WRITE_SET[@]} kubeconfig file(s)"
}
