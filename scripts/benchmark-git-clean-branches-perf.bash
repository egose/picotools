#!/usr/bin/env bash
# shellcheck disable=SC2034 # Planner fixture/output arrays are consumed through nameref parameters.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TOOL="$REPO_ROOT/tools/bin/git-clean-branches"

# shellcheck source=../tools/bin/git-clean-branches
# shellcheck disable=SC1091
. "$TOOL"

usage() {
  cat <<'EOF'
Usage: benchmark-git-clean-branches-perf.bash [--iterations N]

Benchmarks git-clean-branches candidate planning with synthetic disposable
fixtures that vary local-ref and linked-worktree counts. The baseline is the
pre-change nested worktree membership scan. The comparison is the production
planner with an associative worktree-ref set and the same inputs and outputs.

Options:
  --iterations N  Iterations per fixture combination (default: 1)
  -h, --help      Show this help message
EOF
}

collect_git_clean_branches_plan_nested_scan() {
  local remote="$1"
  local current_branch="$2"
  local default_branch="$3"
  local discovered_local_refs_var="$4"
  local discovered_local_oids_var="$5"
  local discovered_remote_refs_var="$6"
  local discovered_remote_oids_var="$7"
  local worktree_branches_var="$8"
  local local_branch_refs_var="$9"
  local local_branch_oids_var="${10}"
  local local_branch_names_var="${11}"
  local remote_tracking_refs_var="${12}"
  local remote_destination_refs_var="${13}"
  local remote_branch_oids_var="${14}"
  local remote_branch_names_var="${15}"

  local -n _gcb_plan_discovered_local_refs="$discovered_local_refs_var"
  local -n _gcb_plan_discovered_local_oids="$discovered_local_oids_var"
  local -n _gcb_plan_discovered_remote_refs="$discovered_remote_refs_var"
  local -n _gcb_plan_discovered_remote_oids="$discovered_remote_oids_var"
  local -n _gcb_plan_worktree_branches="$worktree_branches_var"
  local -n _gcb_plan_local_branch_refs="$local_branch_refs_var"
  local -n _gcb_plan_local_branch_oids="$local_branch_oids_var"
  local -n _gcb_plan_local_branch_names="$local_branch_names_var"
  local -n _gcb_plan_remote_tracking_refs="$remote_tracking_refs_var"
  local -n _gcb_plan_remote_destination_refs="$remote_destination_refs_var"
  local -n _gcb_plan_remote_branch_oids="$remote_branch_oids_var"
  local -n _gcb_plan_remote_branch_names="$remote_branch_names_var"
  local branch ref oid dst_ref
  local local_branch_prefix='refs/heads/'
  local remote_tracking_prefix="refs/remotes/${remote}/"
  local i

  _gcb_plan_local_branch_refs=()
  _gcb_plan_local_branch_oids=()
  _gcb_plan_local_branch_names=()
  _gcb_plan_remote_tracking_refs=()
  _gcb_plan_remote_destination_refs=()
  _gcb_plan_remote_branch_oids=()
  _gcb_plan_remote_branch_names=()

  for i in "${!_gcb_plan_discovered_local_refs[@]}"; do
    ref="${_gcb_plan_discovered_local_refs[$i]}"
    oid="${_gcb_plan_discovered_local_oids[$i]:-}"
    [ -z "$ref" ] && continue
    [ -z "$oid" ] && return 1
    case "$ref" in
    refs/heads/*) ;;
    *) return 1 ;;
    esac

    branch="${ref#"$local_branch_prefix"}"
    [ "$branch" = "$default_branch" ] && continue
    [ "$branch" = "$current_branch" ] && continue
    contains_branch "$branch" "${_gcb_plan_worktree_branches[@]}" && continue

    _gcb_plan_local_branch_refs+=("$ref")
    _gcb_plan_local_branch_oids+=("$oid")
    _gcb_plan_local_branch_names+=("$branch")
  done

  for i in "${!_gcb_plan_discovered_remote_refs[@]}"; do
    ref="${_gcb_plan_discovered_remote_refs[$i]}"
    oid="${_gcb_plan_discovered_remote_oids[$i]:-}"
    [ -z "$ref" ] && continue
    [ -z "$oid" ] && return 1
    [ "$ref" = "refs/remotes/${remote}/HEAD" ] && continue

    case "$ref" in
    refs/remotes/"$remote"/*) ;;
    *) return 1 ;;
    esac

    branch="${ref#"$remote_tracking_prefix"}"
    [ "$branch" = "$default_branch" ] && continue
    [ "$branch" = "$current_branch" ] && continue

    dst_ref="refs/heads/${branch}"
    _gcb_plan_remote_tracking_refs+=("$ref")
    _gcb_plan_remote_destination_refs+=("$dst_ref")
    _gcb_plan_remote_branch_oids+=("$oid")
    _gcb_plan_remote_branch_names+=("$branch")
  done
}

now_ns() {
  date +%s%N
}

elapsed_ms() {
  local start_ns="$1"
  local end_ns="$2"

  printf '%s.%03d' "$(((end_ns - start_ns) / 1000000))" "$((((end_ns - start_ns) / 1000) % 1000))"
}

make_oid() {
  local index="$1"

  printf '%040x\n' "$((index + 1))"
}

make_branch_name() {
  local index="$1"

  case "$index" in
  0) printf 'main\n' ;;
  1) printf 'current\n' ;;
  2) printf 'feature/slash.punct+one\n' ;;
  3) printf -- '-dash-cleanup\n' ;;
  *) printf 'bench/%05d\n' "$index" ;;
  esac
}

prepare_fixture() {
  local local_count="$1"
  local worktree_count="$2"
  local i branch

  discovered_local_refs=()
  discovered_local_oids=()
  discovered_remote_refs=(refs/remotes/origin/HEAD refs/remotes/origin/main refs/remotes/origin/current refs/remotes/origin/feature/slash.punct+one)
  discovered_remote_oids=()
  worktree_branches=()

  for ((i = 0; i < local_count; i++)); do
    branch=$(make_branch_name "$i")
    discovered_local_refs+=("refs/heads/$branch")
    discovered_local_oids+=("$(make_oid "$i")")
  done

  for i in 0 1 2 3; do
    discovered_remote_oids+=("$(make_oid "$((local_count + i))")")
  done

  for ((i = 0; i < worktree_count; i++)); do
    if [ "$i" -lt "$local_count" ]; then
      branch=$(make_branch_name "$i")
    else
      branch="external-worktree/$i"
    fi
    worktree_branches+=("$branch")
  done
}

run_planner_once() {
  local planner="$1"
  local local_branch_refs=()
  local local_branch_oids=()
  local local_branch_names=()
  local remote_tracking_refs=()
  local remote_destination_refs=()
  local remote_branch_oids=()
  local remote_branch_names=()

  "$planner" origin current main discovered_local_refs discovered_local_oids discovered_remote_refs discovered_remote_oids worktree_branches local_branch_refs local_branch_oids local_branch_names remote_tracking_refs remote_destination_refs remote_branch_oids remote_branch_names
}

time_planner() {
  local planner="$1"
  local iterations="$2"
  local start_ns end_ns i

  start_ns=$(now_ns)
  for ((i = 1; i <= iterations; i++)); do
    run_planner_once "$planner"
  done
  end_ns=$(now_ns)
  elapsed_ms "$start_ns" "$end_ns"
}

print_remote_application_counts() {
  local remote_count

  printf '\nRemote application subprocess counts\n'
  printf 'remote_candidates,legacy_per_branch_pushes,current_batch_pushes,current_ls_remote_preflight,current_merge_base_checks\n'
  for remote_count in 0 1 10 100; do
    if [ "$remote_count" -eq 0 ]; then
      printf '%s,0,0,0,0\n' "$remote_count"
    else
      printf '%s,%s,2,1,%s\n' "$remote_count" "$remote_count" "$remote_count"
    fi
  done
}

main() {
  local iterations=1
  local local_count worktree_count nested_ms set_ms

  while [ "$#" -gt 0 ]; do
    case "$1" in
    --iterations)
      [ "$#" -ge 2 ] || {
        printf 'Error: --iterations requires a value\n' >&2
        return 1
      }
      iterations="$2"
      shift 2
      ;;
    -h | --help | help)
      usage
      return 0
      ;;
    *)
      printf 'Error: unknown argument: %s\n' "$1" >&2
      usage >&2
      return 1
      ;;
    esac
  done

  printf 'Tool: %s\n' "$TOOL"
  printf 'Bash: %s\n' "$BASH_VERSION"
  printf 'Git: %s\n' "$(git --version)"
  printf 'Kernel: %s\n' "$(uname -srmo)"
  printf 'Iterations: %s\n\n' "$iterations"

  printf 'Candidate planning benchmark\n'
  printf 'local_refs,linked_worktrees,iterations,baseline_nested_ms,production_associative_set_ms,git_subprocesses\n'
  for local_count in 10 1000 10000; do
    for worktree_count in 1 10 100; do
      prepare_fixture "$local_count" "$worktree_count"
      nested_ms=$(time_planner collect_git_clean_branches_plan_nested_scan "$iterations")
      set_ms=$(time_planner collect_git_clean_branches_plan "$iterations")
      printf '%s,%s,%s,%s,%s,0\n' "$local_count" "$worktree_count" "$iterations" "$nested_ms" "$set_ms"
    done
  done

  print_remote_application_counts
}

main "$@"
