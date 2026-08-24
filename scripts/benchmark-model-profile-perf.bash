#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TOOL="$REPO_ROOT/tools/bin/model-profile"
LOAD_SH="$REPO_ROOT/lib/picotools/load.sh"
PROFILE_COUNTS=(1 25 100)
REPEAT_COUNT=5
BENCHMARK_TMP_ROOT=''

# shellcheck source=../lib/picotools/load.sh
# shellcheck disable=SC1091
. "$LOAD_SH"
picotools_source_modules "$SCRIPT_DIR" box commands config debug prompt table ui version

MODEL_PROFILE_LIB_DIR="$REPO_ROOT/tools/lib/picotools/model-profile"
for MODEL_PROFILE_MODULE in provider token profile; do
  # shellcheck disable=SC1090
  . "$MODEL_PROFILE_LIB_DIR/${MODEL_PROFILE_MODULE}.sh"
done
unset MODEL_PROFILE_MODULE

usage() {
  cat <<'EOF'
Usage: benchmark-model-profile-perf.bash [options]

Options:
  --counts "1 25 100"  Space-separated profile counts to benchmark
  --repeat N            Wall-clock repetitions per scenario (default: 5)
  -h, --help            Show this help message

The fixture creates isolated XDG config/data directories with valid
model-profile config/token pairs, then measures production list/read and
separate parsing, name derivation, validated record, and table rendering probes.
Subprocess counts are collected with temporary BASH_ENV wrappers; wall-clock
timings are measured separately without wrappers to avoid wrapper overhead.
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
      # shellcheck disable=SC2206 # Intentional word splitting for space-separated counts.
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
    --internal)
      shift
      run_internal "$@"
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

sort_numbers() {
  local -n values_ref="$1"
  local i j value

  for ((i = 1; i < ${#values_ref[@]}; i++)); do
    value=${values_ref[i]}
    j=$((i - 1))
    while [ "$j" -ge 0 ] && [ "${values_ref[j]}" -gt "$value" ]; do
      values_ref[j + 1]=${values_ref[j]}
      j=$((j - 1))
    done
    values_ref[j + 1]=$value
  done
}

summarize_wall_distribution() {
  local -n samples_ref="$1"
  local count median_index p95_index min median p95 max total=0 sample mean

  sort_numbers samples_ref
  count=${#samples_ref[@]}
  median_index=$(((count - 1) / 2))
  p95_index=$(((count * 95 + 99) / 100 - 1))
  if [ "$p95_index" -ge "$count" ]; then
    p95_index=$((count - 1))
  fi

  min=${samples_ref[0]}
  median=${samples_ref[median_index]}
  p95=${samples_ref[p95_index]}
  max=${samples_ref[count - 1]}
  for sample in "${samples_ref[@]}"; do
    total=$((total + sample))
  done
  mean=$((total / count))

  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$(format_seconds "$min")" \
    "$(format_seconds "$median")" \
    "$(format_seconds "$p95")" \
    "$(format_seconds "$max")" \
    "$(format_seconds "$mean")"
}

write_profile_file() {
  local file="$1"
  local index="$2"
  local provider_type resource_name endpoint_url models

  case $((index % 4)) in
  0)
    provider_type=custom
    resource_name=''
    printf -v endpoint_url 'https://custom%03d.example.com/openai/v1/' "$index"
    printf -v models 'custom-model-%03d,custom-model-%03d-alt' "$index" "$index"
    ;;
  1)
    provider_type=azure-openai
    printf -v resource_name 'openai%03d' "$index"
    endpoint_url=''
    printf -v models 'gpt-5-%03d,gpt-4o-%03d' "$index" "$index"
    ;;
  2)
    provider_type=azure-cognitive-services
    printf -v resource_name 'vision%03d' "$index"
    endpoint_url=''
    printf -v models 'vision-%03d,document-%03d' "$index" "$index"
    ;;
  *)
    provider_type=gemini
    resource_name=''
    endpoint_url=''
    printf -v models 'gemini-2.5-pro-%03d,gemini-2.5-flash-%03d' "$index" "$index"
    ;;
  esac

  {
    printf '%s\n' '[provider]'
    printf '\ttype = %s\n' "$provider_type"
    if [ -n "$resource_name" ]; then
      printf '\tresourceName = %s\n' "$resource_name"
    fi
    if [ -n "$endpoint_url" ]; then
      printf '\tendpointUrl = %s\n' "$endpoint_url"
    fi
    printf '\tmodels = %s\n' "$models"
  } >"$file"
  chmod 600 "$file"
}

setup_fixture() {
  local root="$1"
  local count="$2"
  local config_home data_home profile_dir data_dir file token_file i name

  config_home="$root/config"
  data_home="$root/data"
  profile_dir="$config_home/model-profile"
  data_dir="$data_home/model-profile"
  mkdir -p "$profile_dir" "$data_dir" "$root/home"
  chmod 700 "$data_dir"

  i=1
  while [ "$i" -le "$count" ]; do
    printf -v name 'profile%03d' "$i"
    file="$profile_dir/$name.conf"
    token_file="$data_dir/$name.token"
    write_profile_file "$file" "$i"
    printf 'token-%03d\n' "$i" >"$token_file"
    chmod 600 "$token_file"
    i=$((i + 1))
  done
}

run_production_operation() {
  local root="$1"
  local operation="$2"
  local config_home="$root/config"
  local data_home="$root/data"

  case "$operation" in
  list)
    HOME="$root/home" XDG_CONFIG_HOME="$config_home" XDG_DATA_HOME="$data_home" bash "$TOOL" list >/dev/null 2>/dev/null
    ;;
  read)
    HOME="$root/home" XDG_CONFIG_HOME="$config_home" XDG_DATA_HOME="$data_home" bash "$TOOL" read <<<"1" >/dev/null 2>/dev/null
    ;;
  *)
    echo "Error: unknown production operation '$operation'" >&2
    exit 1
    ;;
  esac
}

shell_quote_single() {
  local value="$1"
  printf "'%s'" "${value//\'/\'\\\'\'}"
}

create_bash_env_counter() {
  local counter_file="$1"
  local original_path="$2"
  local command_name real_path
  local -a commands=(
    awk
    basename
    bash
    chmod
    dirname
    git
    mkdir
    mktemp
    od
    rm
    sort
    stat
    wc
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

measure_count() {
  local root="$1"
  local scenario="$2"
  local counter_file="$3"
  local log_file="$4"
  local line count=0 git_count=0 awk_count=0

  : >"$log_file"
  (
    export PICOTOOLS_BENCH_PROCESS_LOG="$log_file"
    export BASH_ENV="$counter_file"
    case "$scenario" in
    production-list) run_production_operation "$root" list ;;
    production-read) run_production_operation "$root" read ;;
    *) bash "$0" --internal "$scenario" "$root" >/dev/null 2>/dev/null ;;
    esac
  )

  while IFS= read -r line; do
    count=$((count + 1))
    case "$line" in
    git) git_count=$((git_count + 1)) ;;
    awk) awk_count=$((awk_count + 1)) ;;
    esac
  done <"$log_file"

  printf '%s\t%s\t%s\n' "$git_count" "$awk_count" "$count"
}

measure_wall_distribution() {
  local root="$1"
  local scenario="$2"
  local iteration start end
  local -a samples=()

  iteration=1
  while [ "$iteration" -le "$REPEAT_COUNT" ]; do
    start=$(epoch_us)
    case "$scenario" in
    production-list) run_production_operation "$root" list ;;
    production-read) run_production_operation "$root" read ;;
    *) bash "$0" --internal "$scenario" "$root" >/dev/null 2>/dev/null ;;
    esac
    end=$(epoch_us)
    samples+=("$((end - start))")
    iteration=$((iteration + 1))
  done

  summarize_wall_distribution samples
}

profile_name_shell() {
  local file="$1"
  local name

  name=${file##*/}
  printf '%s\n' "${name%.conf}"
}

saved_fixture_profile_files() {
  saved_profile_files
}

multi_git_parse_probe() {
  local file="$1"
  local name provider_type resource_name endpoint_url models key keys count

  name=$(profile_name_from_file "$file")
  if ! keys=$(git config -f "$file" --name-only --get-regexp '.*' 2>/dev/null); then
    profile_schema_error "$name" 'malformed or empty config'
    return 1
  fi
  while IFS= read -r key; do
    case "$key" in
    provider.type | provider.resourcename | provider.endpointurl | provider.models) ;;
    '') ;;
    *)
      profile_schema_error "$name" "unknown managed key '$key'"
      return 1
      ;;
    esac
  done <<<"$keys"
  for key in provider.type provider.resourceName provider.endpointUrl provider.models; do
    if count=$(git config -f "$file" --get-all "$key" 2>/dev/null | wc -l); then
      :
    else
      count=0
    fi
    if [ "$count" -gt 1 ]; then
      profile_schema_error "$name" "duplicate managed key '$key'"
      return 1
    fi
  done

  provider_type=$(git config -f "$file" --get provider.type 2>/dev/null || true)
  resource_name=$(trim_spaces "$(git config -f "$file" --get provider.resourceName 2>/dev/null || true)")
  endpoint_url=$(normalize_endpoint_url_value "$(git config -f "$file" --get provider.endpointUrl 2>/dev/null || true)")
  models=$(normalize_models_value "$(git config -f "$file" --get provider.models 2>/dev/null || true)")
  validate_profile_schema_values "$name" "$provider_type" "$resource_name" "$endpoint_url" "$models"
}

one_git_parse_probe() {
  local file="$1"
  local name config_lines line key value provider_type='' resource_name='' endpoint_url='' models=''
  local seen=false
  local -A key_counts=()

  name=$(profile_name_shell "$file")
  if ! config_lines=$(git config -f "$file" --list 2>/dev/null); then
    profile_schema_error "$name" 'malformed or empty config'
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    seen=true
    key=${line%%=*}
    value=${line#*=}
    key_counts[$key]=$((${key_counts[$key]:-0} + 1))
    case "$key" in
    provider.type) provider_type=$value ;;
    provider.resourcename) resource_name=$value ;;
    provider.endpointurl) endpoint_url=$value ;;
    provider.models) models=$value ;;
    *)
      profile_schema_error "$name" "unknown managed key '$key'"
      return 1
      ;;
    esac
  done <<<"$config_lines"
  if [ "$seen" != true ]; then
    profile_schema_error "$name" 'malformed or empty config'
    return 1
  fi
  if [ "${key_counts["provider.type"]:-0}" -gt 1 ]; then
    profile_schema_error "$name" "duplicate managed key 'provider.type'"
    return 1
  fi
  if [ "${key_counts["provider.resourcename"]:-0}" -gt 1 ]; then
    profile_schema_error "$name" "duplicate managed key 'provider.resourceName'"
    return 1
  fi
  if [ "${key_counts["provider.endpointurl"]:-0}" -gt 1 ]; then
    profile_schema_error "$name" "duplicate managed key 'provider.endpointUrl'"
    return 1
  fi
  if [ "${key_counts["provider.models"]:-0}" -gt 1 ]; then
    profile_schema_error "$name" "duplicate managed key 'provider.models'"
    return 1
  fi

  resource_name=$(trim_spaces "$resource_name")
  endpoint_url=$(normalize_endpoint_url_value "$endpoint_url")
  models=$(normalize_models_value "$models")
  validate_profile_schema_values "$name" "$provider_type" "$resource_name" "$endpoint_url" "$models"
}

build_rows_one_pass() {
  local file name provider_type resource_name endpoint_url models location token_status status row_index=1

  while IFS= read -r file; do
    one_git_parse_probe "$file" || return 1
    name=$(profile_name_shell "$file")
    provider_type=$(git config -f "$file" --get provider.type 2>/dev/null || true)
    resource_name=$(trim_spaces "$(git config -f "$file" --get provider.resourceName 2>/dev/null || true)")
    endpoint_url=$(normalize_endpoint_url_value "$(git config -f "$file" --get provider.endpointUrl 2>/dev/null || true)")
    models=$(normalize_models_value "$(git config -f "$file" --get provider.models 2>/dev/null || true)")
    location=$resource_name
    if [ -z "$location" ]; then
      location=$endpoint_url
    fi
    if token_exists "$name"; then
      token_status=yes
    else
      status=$?
      [ "$status" -eq 1 ] || return 1
      token_status=no
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$row_index" "$name" "$(provider_type_label "$provider_type")" "$(display_value "$location")" "$(display_value "$models")" "$token_status"
    row_index=$((row_index + 1))
  done < <(saved_fixture_profile_files)
}

render_table_native() {
  local header_row="$1"
  shift
  local -a rows=("$@") headers=() widths=() fields=()
  local row index field padding

  IFS=$'\t' read -r -a headers <<<"$header_row"
  for index in "${!headers[@]}"; do
    widths[index]=${#headers[index]}
  done
  for row in "${rows[@]}"; do
    IFS=$'\t' read -r -a fields <<<"$row"
    for index in "${!headers[@]}"; do
      field=${fields[index]:-}
      if [ "${#field}" -gt "${widths[index]}" ]; then
        widths[index]=${#field}
      fi
    done
  done

  for index in "${!headers[@]}"; do
    padding=$(printf '%*s' "$((widths[index] + 2))" '')
    printf '+%s' "${padding// /-}"
  done
  printf '+\n'
  for index in "${!headers[@]}"; do
    printf '| %s' "${headers[index]}"
    printf '%*s ' "$((widths[index] - ${#headers[index]}))" ''
  done
  printf '|\n'
  for index in "${!headers[@]}"; do
    padding=$(printf '%*s' "$((widths[index] + 2))" '')
    printf '+%s' "${padding// /-}"
  done
  printf '+\n'
  for row in "${rows[@]}"; do
    IFS=$'\t' read -r -a fields <<<"$row"
    for index in "${!headers[@]}"; do
      field=${fields[index]:-}
      printf '| %s' "$field"
      printf '%*s ' "$((widths[index] - ${#field}))" ''
    done
    printf '|\n'
  done
  for index in "${!headers[@]}"; do
    padding=$(printf '%*s' "$((widths[index] + 2))" '')
    printf '+%s' "${padding// /-}"
  done
  printf '+\n'
}

run_internal() {
  local scenario="$1"
  local root="$2"
  local config_home="$root/config"
  local data_home="$root/data"
  local file name
  local -a files=() rows=()

  export HOME="$root/home"
  export XDG_CONFIG_HOME="$config_home"
  export XDG_DATA_HOME="$data_home"

  while IFS= read -r file; do
    files+=("$file")
  done < <(saved_fixture_profile_files)

  case "$scenario" in
  name-basename)
    for file in "${files[@]}"; do
      profile_name_from_file "$file" >/dev/null
    done
    ;;
  name-shell)
    for file in "${files[@]}"; do
      profile_name_shell "$file" >/dev/null
    done
    ;;
  parse-multi-git)
    for file in "${files[@]}"; do
      multi_git_parse_probe "$file"
    done
    ;;
  parse-one-git)
    for file in "${files[@]}"; do
      one_git_parse_probe "$file"
    done
    ;;
  records-multi-git)
    for file in "${files[@]}"; do
      multi_git_parse_probe "$file"
      name=$(profile_name_from_file "$file")
      token_exists "$name" || [ "$?" -eq 1 ]
    done
    ;;
  records-one-git)
    for file in "${files[@]}"; do
      one_git_parse_probe "$file"
      name=$(profile_name_shell "$file")
      token_exists "$name" || [ "$?" -eq 1 ]
    done
    ;;
  table-shared)
    while IFS= read -r file; do
      name=$(profile_name_shell "$file")
      rows+=("$name	$name	Azure OpenAI	openai001	gpt-5,gpt-4o	yes")
    done < <(saved_fixture_profile_files)
    picotools_print_table $'#	Name	Type	Resource	Models	Token' "${rows[@]}"
    ;;
  table-native)
    while IFS= read -r file; do
      name=$(profile_name_shell "$file")
      rows+=("$name	$name	Azure OpenAI	openai001	gpt-5,gpt-4o	yes")
    done < <(saved_fixture_profile_files)
    render_table_native $'#	Name	Type	Resource	Models	Token' "${rows[@]}"
    ;;
  records-one-git-output)
    build_rows_one_pass
    ;;
  *)
    echo "Error: unknown internal scenario '$scenario'" >&2
    exit 1
    ;;
  esac
}

print_environment() {
  printf '# environment: uname=%s\n' "$(uname -a)"
  printf '# environment: bash=%s\n' "$BASH_VERSION"
  printf '# environment: git=%s\n' "$(git --version)"
  printf '# environment: awk=%s\n' "$(awk -W version 2>&1 | while IFS= read -r line; do
    printf '%s\n' "$line"
    break
  done)"
  printf '# environment: tool=%s\n' "$TOOL"
  printf '# command: %s\n' "$0 $*"
  printf '# fixture: TMPDIR-isolated HOME/XDG_CONFIG_HOME/XDG_DATA_HOME; N valid .conf/.token pairs; mixed azure-openai, azure-cognitive-services, gemini, custom profiles; token files mode 0600, token directory mode 0700\n'
  printf '# wall columns: min_seconds median_seconds p95_seconds max_seconds mean_seconds over --repeat runs\n'
}

print_measurement() {
  local root="$1"
  local scenario="$2"
  local count_file="$3"
  local log_file="$4"
  local process_counts wall_distribution

  process_counts=$(measure_count "$root" "$scenario" "$count_file" "$log_file")
  wall_distribution=$(measure_wall_distribution "$root" "$scenario")
  printf '%s\t%s\t%s\n' "$scenario" "$process_counts" "$wall_distribution"
}

main() {
  local bench_root counter_file log_file count original_path
  local -a scenarios=(
    production-list
    production-read
    name-basename
    name-shell
    parse-multi-git
    parse-one-git
    records-multi-git
    records-one-git
    table-shared
    table-native
  )
  local scenario

  parse_args "$@"
  validate_args

  bench_root=$(mktemp -d)
  BENCHMARK_TMP_ROOT="$bench_root"
  trap 'rm -rf "$BENCHMARK_TMP_ROOT"' EXIT
  counter_file="$bench_root/bash-env-counter.bash"
  log_file="$bench_root/process.log"
  original_path="$PATH"
  create_bash_env_counter "$counter_file" "$original_path"

  print_environment "$@"
  printf 'profiles\tscenario\tgit_subprocesses\tawk_subprocesses\ttracked_subprocesses\tmin_seconds\tmedian_seconds\tp95_seconds\tmax_seconds\tmean_seconds\n'
  for count in "${PROFILE_COUNTS[@]}"; do
    setup_fixture "$bench_root/profiles-$count" "$count"
    for scenario in "${scenarios[@]}"; do
      printf '%s\t' "$count"
      print_measurement "$bench_root/profiles-$count" "$scenario" "$counter_file" "$log_file"
    done
  done
}

main "$@"
