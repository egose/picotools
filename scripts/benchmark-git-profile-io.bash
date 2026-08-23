#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TOOL="$REPO_ROOT/tools/bin/git-profile"
PROFILE_COUNTS=(1 25 100)
OPERATIONS=(list read update)
REPEAT_COUNT=5
BENCHMARK_TMP_ROOT=''

usage() {
  cat <<'EOF'
Usage: benchmark-git-profile-io.bash [options]

Options:
  --counts "1 25 100"  Space-separated profile counts to benchmark
  --repeat N            Wall-clock repetitions per scenario (default: 5)
  -h, --help            Show this help message

The fixture creates isolated XDG config/data directories, generates synthetic
git-profile config/token files, then measures list, selected read, and no-op
update. Subprocess counts are external command invocations observed through
temporary PATH wrappers; wall-clock timings are measured separately without
wrappers to avoid wrapper overhead.
EOF
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
    --counts)
      if [ "$#" -lt 2 ]; then
        echo 'Error: --counts requires a value' >&2
        exit 1
      fi
      # shellcheck disable=SC2206 # intentional word splitting for space-separated counts
      PROFILE_COUNTS=($2)
      shift 2
      ;;
    --repeat)
      if [ "$#" -lt 2 ]; then
        echo 'Error: --repeat requires a value' >&2
        exit 1
      fi
      REPEAT_COUNT="$2"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "Error: unknown option '$1'" >&2
      usage >&2
      exit 1
      ;;
    esac
  done
}

validate_args() {
  local count

  if ! [[ "$REPEAT_COUNT" =~ ^[1-9][0-9]*$ ]]; then
    echo 'Error: --repeat must be a positive integer' >&2
    exit 1
  fi

  for count in "${PROFILE_COUNTS[@]}"; do
    if ! [[ "$count" =~ ^[1-9][0-9]*$ ]]; then
      echo "Error: profile count must be a positive integer: $count" >&2
      exit 1
    fi
  done
}

epoch_us() {
  local epoch="$EPOCHREALTIME"
  local seconds micros

  seconds=${epoch%.*}
  micros=${epoch#*.}
  micros=${micros:0:6}
  while [ "${#micros}" -lt 6 ]; do
    micros="${micros}0"
  done

  printf '%s\n' "$((10#$seconds * 1000000 + 10#$micros))"
}

format_seconds() {
  local micros="$1"
  local seconds fraction

  seconds=$((micros / 1000000))
  fraction=$((micros % 1000000))
  printf '%d.%06d\n' "$seconds" "$fraction"
}

write_profile_file() {
  local file="$1"
  local index="$2"
  local name email

  printf -v name 'User %03d' "$index"
  printf -v email 'user%03d@example.com' "$index"

  {
    printf '%s\n' '[user]'
    printf '\tname = %s\n' "$name"
    printf '\temail = %s\n' "$email"
    printf '%s\n' '[commit]'
    printf '\tgpgsign = false\n'
    printf '%s\n' '[tag]'
    printf '\tgpgsign = false\n'
    printf '%s\n' '[core]'
    printf '\tautocrlf = false\n'
    printf '\tfileMode = true\n'
    printf '\teditor = vim\n'
    printf '%s\n' '[pull]'
    printf '\trebase = false\n'
    printf '%s\n' '[rebase]'
    printf '\tautoStash = false\n'
    printf '%s\n' '[push]'
    printf '\tdefault = simple\n'
    printf '\tautoSetupRemote = false\n'
    printf '%s\n' '[picotools]'
    printf '\tsshAddOnStart = false\n'
  } >"$file"
  chmod 600 "$file"
}

setup_fixture() {
  local root="$1"
  local count="$2"
  local config_home data_home profile_dir data_dir file token_file i name

  config_home="$root/config"
  data_home="$root/data"
  profile_dir="$config_home/git-profile"
  data_dir="$data_home/git-profile"
  mkdir -p "$profile_dir" "$data_dir"
  chmod 700 "$data_dir"

  i=1
  while [ "$i" -le "$count" ]; do
    printf -v name 'profile%03d' "$i"
    file="$profile_dir/$name.gitconfig"
    write_profile_file "$file" "$i"

    if [ $((i % 2)) -eq 0 ]; then
      token_file="$data_dir/$name.token"
      printf 'token-%03d\n' "$i" >"$token_file"
      chmod 600 "$token_file"
    fi

    i=$((i + 1))
  done
}

run_operation() {
  local root="$1"
  local operation="$2"
  local config_home="$root/config"
  local data_home="$root/data"
  local bash_command="${PICOTOOLS_BENCH_BASH:-bash}"

  case "$operation" in
  list)
    HOME="$root/home" XDG_CONFIG_HOME="$config_home" XDG_DATA_HOME="$data_home" "$bash_command" "$TOOL" list >/dev/null 2>/dev/null
    ;;
  read)
    HOME="$root/home" XDG_CONFIG_HOME="$config_home" XDG_DATA_HOME="$data_home" "$bash_command" "$TOOL" read <<<"1" >/dev/null 2>/dev/null
    ;;
  update)
    HOME="$root/home" XDG_CONFIG_HOME="$config_home" XDG_DATA_HOME="$data_home" "$bash_command" "$TOOL" update <<<$'1\n11' >/dev/null 2>/dev/null
    ;;
  *)
    echo "Error: unknown benchmark operation '$operation'" >&2
    exit 1
    ;;
  esac
}

shell_quote_single() {
  local value="$1"
  printf "'%s'" "${value//\'/\'\\\'\'}"
}

create_command_wrapper() {
  local wrapper="$1"
  local command_name="$2"
  local real_path="$3"

  {
    printf '%s\n' '#!/bin/sh'
    printf '%s\n' 'set -eu'
    printf "printf %%s\\\\n %s >>\"\$PICOTOOLS_BENCH_PROCESS_LOG\"\n" "$(shell_quote_single "$command_name")"
    printf 'exec %s "$@"\n' "$(shell_quote_single "$real_path")"
  } >"$wrapper"
  chmod +x "$wrapper"
}

create_path_wrappers() {
  local wrapper_dir="$1"
  local original_path="$2"
  local command_name real_path
  local -a commands=(
    bash
    basename
    chmod
    cp
    dirname
    git
    mkdir
    mktemp
    mv
    rm
    sort
    stat
  )

  for command_name in "${commands[@]}"; do
    real_path=$(PATH="$original_path" command -v "$command_name") || continue
    create_command_wrapper "$wrapper_dir/$command_name" "$command_name" "$real_path"
  done
}

create_bash_env_counter() {
  local counter_file="$1"
  local original_path="$2"
  local command_name real_path
  local -a commands=(
    basename
    chmod
    cp
    dirname
    git
    mkdir
    mktemp
    mv
    rm
    sort
    stat
  )

  {
    # shellcheck disable=SC2016 # Emitted into the generated BASH_ENV file.
    printf '%s\n' 'if [ "${PICOTOOLS_BENCH_COUNTER_LOADED:-0}" -eq 1 ]; then return 0; fi'
    printf '%s\n' 'PICOTOOLS_BENCH_COUNTER_LOADED=1'
    for command_name in "${commands[@]}"; do
      real_path=$(PATH="$original_path" command -v "$command_name") || continue
      # shellcheck disable=SC2016 # Emitted into the generated BASH_ENV file.
      printf '%s() { printf '\''%%s\n'\'' %s >>"${PICOTOOLS_BENCH_PROCESS_LOG:?}"; command %s "$@"; }\n' \
        "$command_name" \
        "$(shell_quote_single "$command_name")" \
        "$(shell_quote_single "$real_path")"
    done
  } >"$counter_file"
}

measure_subprocesses() {
  local root="$1"
  local operation="$2"
  local counter_file="$3"
  local log_file="$4"
  local count=0 _line

  : >"$log_file"
  (
    export PICOTOOLS_BENCH_PROCESS_LOG="$log_file"
    export BASH_ENV="$counter_file"
    run_operation "$root" "$operation"
  )
  while IFS= read -r _line; do
    count=$((count + 1))
  done <"$log_file"
  printf '%s\n' "$count"
}

measure_wall_us() {
  local root="$1"
  local operation="$2"
  local iteration start end total=0

  iteration=1
  while [ "$iteration" -le "$REPEAT_COUNT" ]; do
    start=$(epoch_us)
    run_operation "$root" "$operation"
    end=$(epoch_us)
    total=$((total + end - start))
    iteration=$((iteration + 1))
  done

  printf '%s\n' "$((total / REPEAT_COUNT))"
}

print_environment() {
  printf '# environment: uname=%s\n' "$(uname -a)"
  printf '# environment: bash=%s\n' "${BASH_VERSION}"
  printf '# environment: git=%s\n' "$(git --version)"
  printf '# environment: tool=%s\n' "$TOOL"
  printf '# command: %s\n' "$0 $*"
  printf '# generated fixture: TMPDIR-isolated XDG_CONFIG_HOME/XDG_DATA_HOME per profile count\n'
  printf '# measured commands: git-profile list; printf selection | git-profile read; printf selection/done | git-profile update\n'
}

main() {
  local bench_root counter_file log_file count operation subprocesses wall_us original_path

  parse_args "$@"
  validate_args

  bench_root=$(mktemp -d)
  BENCHMARK_TMP_ROOT="$bench_root"
  trap 'rm -rf "$BENCHMARK_TMP_ROOT"' EXIT
  counter_file="$bench_root/bash-env-counter.bash"
  log_file="$bench_root/process.log"
  mkdir -p "$bench_root"
  # shellcheck disable=SC2031 # The measured PATH override above is scoped to its subshell.
  original_path="$PATH"
  create_bash_env_counter "$counter_file" "$original_path"

  print_environment "$@"
  printf 'profiles\toperation\tsubprocesses\twall_seconds\n'
  for count in "${PROFILE_COUNTS[@]}"; do
    setup_fixture "$bench_root/profiles-$count" "$count"
    for operation in "${OPERATIONS[@]}"; do
      subprocesses=$(measure_subprocesses "$bench_root/profiles-$count" "$operation" "$counter_file" "$log_file")
      wall_us=$(measure_wall_us "$bench_root/profiles-$count" "$operation")
      printf '%s\t%s\t%s\t%s\n' "$count" "$operation" "$subprocesses" "$(format_seconds "$wall_us")"
    done
  done
}

main "$@"
