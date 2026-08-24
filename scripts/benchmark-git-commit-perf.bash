#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SIZES=${GIT_COMMIT_PERF_SIZES:-"10 1000 10000"}
MODES=${GIT_COMMIT_PERF_MODES:-"diff-current diff-untracked-map-candidate diff-batched-candidate diff-current-budget plan-current plan-normalized-candidate lookup-linear lookup-map"}
BENCH_TMP_ROOT=${GIT_COMMIT_PERF_TMP_ROOT:-}
KEEP_TMP=${GIT_COMMIT_PERF_KEEP_TMP:-false}

usage() {
  cat <<'EOF'
Usage: benchmark-git-commit-perf.bash [options]

Creates disposable Git repositories with 10, 1000, and 10000 changed files by
default, then reports wall-clock time plus wrapped git/jq subprocess counts.

Environment:
  GIT_COMMIT_PERF_SIZES="10 1000 10000"       Space-delimited changed-file counts
  GIT_COMMIT_PERF_MODES="diff-current ..."    Space-delimited benchmark modes
  GIT_COMMIT_PERF_TMP_ROOT=/tmp/path           Reuse or inspect a temp root
  GIT_COMMIT_PERF_KEEP_TMP=true                Preserve generated repos and wrappers

Modes:
  diff-current                Current collect_changes_diff production path
  diff-untracked-map-candidate Candidate that avoids per-file tracked checks
  diff-batched-candidate      Candidate one-shot tracked git diff collection
  diff-current-budget         Current diff path with a small prompt budget
  plan-current                Current validation/render parsing path
  plan-normalized-candidate   Candidate one-pass jq plan normalization
  lookup-linear               Repeated changed_files_include_path lookups
  lookup-map                  Associative-array lookup map probes
EOF
}

cleanup() {
  if [ -n "$BENCH_TMP_ROOT" ] && [ "$KEEP_TMP" != 'true' ]; then
    rm -rf "$BENCH_TMP_ROOT"
  fi
}

require_command() {
  local tool="$1"

  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'Error: required benchmark tool not found: %s\n' "$tool" >&2
    return 1
  fi
}

now_ns() {
  date +%s%N
}

elapsed_ms() {
  local start_ns="$1"
  local end_ns="$2"

  printf '%s\n' $(((end_ns - start_ns) / 1000000))
}

count_processes() {
  local count_file="$1"
  local process_name="$2"
  local count=0 line

  if [ ! -f "$count_file" ]; then
    printf '0\n'
    return 0
  fi

  while IFS= read -r line; do
    if [ "$line" = "$process_name" ]; then
      count=$((count + 1))
    fi
  done <"$count_file"

  printf '%s\n' "$count"
}

write_wrappers() {
  local wrapper_dir="$1"
  local real_git="$2"
  local real_jq="$3"

  mkdir -p "$wrapper_dir"
  cat >"$wrapper_dir/git" <<EOF
#!/usr/bin/env bash
if [ -n "\${PICOTOOLS_BENCH_COUNT_FILE:-}" ]; then
  printf 'git\\n' >>"\$PICOTOOLS_BENCH_COUNT_FILE"
fi
exec "$real_git" "\$@"
EOF
  cat >"$wrapper_dir/jq" <<EOF
#!/usr/bin/env bash
if [ -n "\${PICOTOOLS_BENCH_COUNT_FILE:-}" ]; then
  printf 'jq\\n' >>"\$PICOTOOLS_BENCH_COUNT_FILE"
fi
exec "$real_jq" "\$@"
EOF
  chmod +x "$wrapper_dir/git" "$wrapper_dir/jq"
}

setup_repo() {
  local size="$1"
  local repo="$2"
  local index file

  mkdir -p "$repo/files"
  git -C "$repo" init -q
  git -C "$repo" config user.name 'Benchmark User'
  git -C "$repo" config user.email benchmark@example.com
  for ((index = 1; index <= size; index++)); do
    printf -v file 'files/file-%05d.txt' "$index"
    printf 'base %05d\n' "$index" >"$repo/$file"
  done
  git -C "$repo" add files
  git -C "$repo" commit -qm 'baseline files'
  for ((index = 1; index <= size; index++)); do
    printf -v file 'files/file-%05d.txt' "$index"
    printf 'changed %05d\n' "$index" >>"$repo/$file"
  done
}

plan_json_for_size() {
  local size="$1"
  local index file separator=''

  printf '{"commits":[{"type":"feat","message":"update benchmark files","files":['
  for ((index = 1; index <= size; index++)); do
    printf -v file 'files/file-%05d.txt' "$index"
    printf '%s"%s"' "$separator" "$file"
    separator=','
  done
  printf ']}]}'
}

run_mode() {
  local mode="$1"
  local repo="$2"
  local size="$3"
  local plan_file="$4"

  case "$mode" in
  diff-current)
    bash -lc '
      set -euo pipefail
      cd "$1"
      debug_log() { :; }
      MAX_COMMIT_PLAN_ADDED_FILE_BYTES=65536
      MAX_COMMIT_PLAN_FILE_DIFF_CHARS=16384
      MAX_COMMIT_PLAN_DIFF_CHARS=50000
      . "$2/lib/picotools/git_commit_workspace.sh"
      collect_changed_files_into changed_files
      collect_changes_diff changed_files >/dev/null
    ' _ "$repo" "$REPO_ROOT"
    ;;
  diff-untracked-map-candidate)
    bash -lc '
      set -euo pipefail
      cd "$1"
      debug_log() { :; }
      MAX_COMMIT_PLAN_ADDED_FILE_BYTES=65536
      MAX_COMMIT_PLAN_FILE_DIFF_CHARS=16384
      MAX_COMMIT_PLAN_DIFF_CHARS=50000
      . "$2/lib/picotools/git_commit_workspace.sh"
      collect_changes_diff_with_untracked_map() {
        local changed_files_ref_name="$1"
        local repo_root file file_diff pathspec
        local has_head=false diff_output=""
        local -A untracked_file_set=()
        local -n changed_files_ref="$changed_files_ref_name"

        repo_root=$(git_repo_root)
        if git rev-parse --verify HEAD >/dev/null 2>&1; then
          has_head=true
        fi
        while IFS= read -r -d "" file; do
          untracked_file_set["$file"]=1
        done < <(git -C "$repo_root" ls-files -z --others --exclude-standard)

        for file in "${changed_files_ref[@]}"; do
          if [ -n "${untracked_file_set[$file]:-}" ]; then
            file_diff=$(added_file_diff_for_prompt "$repo_root" "$file")
          else
            pathspec=$(git_literal_pathspec "$file")
            if [ "$has_head" = true ]; then
              file_diff=$(git -C "$repo_root" diff --no-ext-diff HEAD -- "$pathspec")
            else
              file_diff=$(git -C "$repo_root" diff --no-ext-diff --cached -- "$pathspec")
            fi
            if [ "${#file_diff}" -gt "$MAX_COMMIT_PLAN_FILE_DIFF_CHARS" ]; then
              file_diff="[Omitted diff for $file because its diff size (${#file_diff} chars) exceeds the prompt limit per file ($MAX_COMMIT_PLAN_FILE_DIFF_CHARS chars).]"
            fi
          fi
          [ -n "$file_diff" ] || continue
          if [ -n "$diff_output" ]; then diff_output+=$'"'"'\n'"'"'; fi
          diff_output+="$file_diff"
          if [ "${#diff_output}" -gt "$MAX_COMMIT_PLAN_DIFF_CHARS" ]; then
            diff_output+=$'"'"'\n[Stopped collecting additional diffs after reaching the prompt diff budget.]'"'"'
            break
          fi
        done
        printf "%s\n" "$diff_output"
      }
      collect_changed_files_into changed_files
      collect_changes_diff_with_untracked_map changed_files >/dev/null
    ' _ "$repo" "$REPO_ROOT"
    ;;
  diff-batched-candidate)
    bash -lc '
      set -euo pipefail
      cd "$1"
      debug_log() { :; }
      MAX_COMMIT_PLAN_ADDED_FILE_BYTES=65536
      MAX_COMMIT_PLAN_FILE_DIFF_CHARS=16384
      MAX_COMMIT_PLAN_DIFF_CHARS=50000
      . "$2/lib/picotools/git_commit_workspace.sh"
      collect_changed_files_into changed_files
      git_literal_pathspecs_into pathspecs "${changed_files[@]}"
      git diff --no-ext-diff HEAD -- "${pathspecs[@]}" >/dev/null
    ' _ "$repo" "$REPO_ROOT"
    ;;
  diff-current-budget)
    bash -lc '
      set -euo pipefail
      cd "$1"
      debug_log() { :; }
      MAX_COMMIT_PLAN_ADDED_FILE_BYTES=65536
      MAX_COMMIT_PLAN_FILE_DIFF_CHARS=16384
      MAX_COMMIT_PLAN_DIFF_CHARS=2000
      . "$2/lib/picotools/git_commit_workspace.sh"
      collect_changed_files_into changed_files
      collect_changes_diff changed_files >/dev/null
    ' _ "$repo" "$REPO_ROOT"
    ;;
  plan-current)
    bash -lc '
      set -euo pipefail
      debug_log() { :; }
      ALLOWED_TYPES="feat fix docs refactor chore perf test ci"
      MAX_COMMIT_HEADER_LENGTH=100
      PRE_COMMIT_CONFIG_FILE=.pre-commit-config.yaml
      . "$1/lib/picotools/git_commit_workspace.sh"
      . "$1/lib/picotools/git_commit_plan.sh"
      . "$1/lib/picotools/box.sh"
      . "$1/lib/picotools/git_commit_execution.sh"
      plan_json=$(<"$2")
      for ((index = 1; index <= $3; index++)); do
        printf -v file "files/file-%05d.txt" "$index"
        changed_files+=("$file")
      done
      run_commit_plan_validation "$plan_json" changed_files false >/dev/null
      print_commit_plan "$plan_json" "" changed_files >/dev/null
    ' _ "$REPO_ROOT" "$plan_file" "$size"
    ;;
  plan-normalized-candidate)
    bash -lc '
      set -euo pipefail
      jq -r "[.commits[] | .type, .message, (.files[])] | @json" "$1" >/dev/null
    ' _ "$plan_file"
    ;;
  lookup-linear)
    bash -lc '
      set -euo pipefail
      . "$1/lib/picotools/git_commit_workspace.sh"
      for ((index = 1; index <= $2; index++)); do
        printf -v file "files/file-%05d.txt" "$index"
        changed_files+=("$file")
      done
      for file in "${changed_files[@]}"; do
        changed_files_include_path changed_files "$file"
      done
    ' _ "$REPO_ROOT" "$size"
    ;;
  lookup-map)
    bash -lc '
      set -euo pipefail
      . "$1/lib/picotools/git_commit_plan.sh"
      declare -A changed_file_set=()
      for ((index = 1; index <= $2; index++)); do
        printf -v file "files/file-%05d.txt" "$index"
        changed_files+=("$file")
      done
      build_changed_file_lookup_map changed_files changed_file_set
      for file in "${changed_files[@]}"; do
        [ -n "${changed_file_set[$file]:-}" ]
      done
    ' _ "$REPO_ROOT" "$size"
    ;;
  *)
    printf 'Error: unknown benchmark mode: %s\n' "$mode" >&2
    return 1
    ;;
  esac
}

measure_mode() {
  local mode="$1"
  local repo="$2"
  local size="$3"
  local plan_file="$4"
  local wrapper_dir="$5"
  local count_file start_ns end_ns status git_count jq_count elapsed

  count_file="$BENCH_TMP_ROOT/count-$mode-$size.log"
  : >"$count_file"
  start_ns=$(now_ns)
  status=0
  PATH="$wrapper_dir:$PATH" PICOTOOLS_BENCH_COUNT_FILE="$count_file" run_mode "$mode" "$repo" "$size" "$plan_file" || status=$?
  end_ns=$(now_ns)
  elapsed=$(elapsed_ms "$start_ns" "$end_ns")
  git_count=$(count_processes "$count_file" git)
  jq_count=$(count_processes "$count_file" jq)
  printf '%s,%s,%s,%s,%s,%s\n' "$mode" "$size" "$elapsed" "$git_count" "$jq_count" "$status"
}

main() {
  local arg size mode real_git real_jq wrapper_dir repo plan_file

  for arg in "$@"; do
    case "$arg" in
    -h | --help | help)
      usage
      exit 0
      ;;
    *)
      printf 'Error: unknown option: %s\n' "$arg" >&2
      usage >&2
      exit 1
      ;;
    esac
  done

  require_command git
  require_command jq
  require_command date
  require_command mktemp

  real_git=$(command -v git)
  real_jq=$(command -v jq)
  if [ -z "$BENCH_TMP_ROOT" ]; then
    BENCH_TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/git-commit-perf.XXXXXX")
  else
    mkdir -p "$BENCH_TMP_ROOT"
  fi
  trap cleanup EXIT

  wrapper_dir="$BENCH_TMP_ROOT/bin"
  write_wrappers "$wrapper_dir" "$real_git" "$real_jq"

  printf 'repo_root=%s\n' "$REPO_ROOT"
  printf 'tmp_root=%s\n' "$BENCH_TMP_ROOT"
  printf 'bash=%s\n' "${BASH_VERSION:-unknown}"
  printf 'git=%s\n' "$(git --version)"
  printf 'jq=%s\n' "$(jq --version)"
  printf 'mode,size,wall_ms,git_processes,jq_processes,status\n'

  for size in $SIZES; do
    repo="$BENCH_TMP_ROOT/repo-$size"
    plan_file="$BENCH_TMP_ROOT/plan-$size.json"
    setup_repo "$size" "$repo"
    plan_json_for_size "$size" >"$plan_file"
    for mode in $MODES; do
      measure_mode "$mode" "$repo" "$size" "$plan_file" "$wrapper_dir"
    done
  done
}

main "$@"
