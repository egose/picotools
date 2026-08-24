#!/usr/bin/env bats

# shellcheck disable=SC2034 # Direct tests pass fixture arrays to nameref parameters.

# shellcheck source=helpers/git-clean-branches.bash
# shellcheck disable=SC1091
source "$BATS_TEST_DIRNAME/helpers/git-clean-branches.bash"

setup() {
  setup_git_clean_branches_test_home
}

teardown() {
  teardown_git_clean_branches_test_home
}

@test "does not list symbolic remote head as a remote branch" {
  local remote_section

  create_repo_with_remote
  create_merged_remote_branch
  checkout_topic_branch

  run_git_clean_branches "$REPO_DIR" 'n\n'

  [ "$status" -eq 1 ] || fail 'cancelling the prompt should exit non-zero'
  assert_contains "$output" 'Remote branches to delete:' 'should list merged remote branches'
  remote_section="$(extract_plan_section "$output" 'Remote branches to delete:')"
  assert_contains "$remote_section" '  merged-remote' 'should include merged remote branches'
  assert_not_contains "$remote_section"$'\n' $'  HEAD\n' 'should not treat the symbolic remote head as a branch'
}

@test "deletes merged remote branches after confirmation" {
  create_repo_with_remote
  create_merged_remote_branch

  run_git_clean_branches "$REPO_DIR" 'y\n'

  [ "$status" -eq 0 ] || fail 'confirming the reviewed plan should succeed'
  assert_contains "$output" 'Remote branches to delete:' 'should render remote deletion plan'
  assert_contains "$output" '  merged-remote' 'should plan the merged remote branch'
  assert_remote_branch_missing "$REMOTE_DIR" 'merged-remote' 'should delete merged remote branches from the remote'
}

@test "preserves unmerged remote branches" {
  create_repo_with_remote
  create_unmerged_remote_branch

  run_git_clean_branches "$REPO_DIR" 'y\n'

  [ "$status" -eq 0 ] || fail 'cleaning should succeed with an unmerged remote branch present'
  assert_not_contains "$output" 'Remote branches to delete:' 'should not plan unmerged remote branches'
  assert_remote_branch_exists "$REMOTE_DIR" 'unmerged-remote' 'should preserve unmerged remote branches'
}

@test "force-deletes unmerged local branches" {
  create_repo_with_remote
  create_unmerged_local_branch

  run_git_clean_branches "$REPO_DIR" 'y\n'

  [ "$status" -eq 0 ] || fail 'cleaning should succeed for an unmerged local branch'
  assert_contains "$output" 'Local branches to delete:' 'should render local deletion plan'
  assert_contains "$output" '  unmerged-local' 'should plan the unmerged local branch'
  assert_branch_missing "$REPO_DIR" 'unmerged-local' 'should force-delete unmerged local branches'
}

@test "preserves default current and linked-worktree branches" {
  local worktree_dir

  create_repo_with_remote
  create_merged_remote_branch 'cleanup-runner'
  git -C "$REPO_DIR" branch worktree-branch main
  mkdir -p "$TMP_HOME/worktrees"
  worktree_dir="$TMP_HOME/worktrees/worktree-branch"
  git -C "$REPO_DIR" worktree add -q "$worktree_dir" worktree-branch
  git -C "$REPO_DIR" checkout -q cleanup-runner

  run_git_clean_branches "$REPO_DIR" 'y\n'

  [ "$status" -eq 0 ] || fail 'cleaning should succeed while protected branches exist'
  assert_not_contains "$output" '  main' 'should not plan the default branch'
  assert_not_contains "$output" '  cleanup-runner' 'should not plan the current branch'
  assert_not_contains "$output" '  worktree-branch' 'should not plan branches checked out in another worktree'
  assert_branch_exists "$REPO_DIR" 'main' 'should preserve the default branch'
  assert_branch_exists "$REPO_DIR" 'cleanup-runner' 'should preserve the current branch'
  assert_branch_exists "$REPO_DIR" 'worktree-branch' 'should preserve branches checked out in another worktree'
  assert_remote_branch_exists "$REMOTE_DIR" 'main' 'should preserve the remote default branch'
  assert_remote_branch_exists "$REMOTE_DIR" 'cleanup-runner' 'should preserve the remote current branch'
}

@test "fails when the selected remote is missing" {
  create_repo_with_remote

  run_git_clean_branches_without_stdin "$REPO_DIR" --yes upstream

  [ "$status" -eq 1 ] || fail 'missing remote should fail'
  assert_contains "$output" "Error: remote 'upstream' does not exist" 'should explain the missing remote'
}

@test "fails outside a git repository" {
  local non_repo

  non_repo="$TMP_HOME/non-repo"
  mkdir -p "$non_repo"

  run_git_clean_branches_without_stdin "$non_repo" --yes

  [ "$status" -eq 1 ] || fail 'non-repository invocation should fail'
  assert_contains "$output" 'Error: current directory is not a git repository' 'should explain that a git repository is required'
}

@test "rejects unknown options before running git" {
  local non_repo

  non_repo="$TMP_HOME/non-repo"
  mkdir -p "$non_repo"

  run_git_clean_branches_without_git "$non_repo" --bogus

  [ "$status" -eq 1 ] || fail 'unknown options should fail'
  assert_contains "$output" 'Error: unknown option: --bogus' 'should report the unknown option'
  assert_contains "$output" 'Usage: git-clean-branches [--yes] [--debug] [--] [remote]' 'should print usage on option errors'
  assert_not_contains "$output" 'git should not run during argument parsing' 'should reject unknown options before invoking git'
}

@test "rejects excess positional arguments before running git" {
  local non_repo

  non_repo="$TMP_HOME/non-repo"
  mkdir -p "$non_repo"

  run_git_clean_branches_without_git "$non_repo" origin extra

  [ "$status" -eq 1 ] || fail 'excess positional arguments should fail'
  assert_contains "$output" 'Error: unexpected argument: extra' 'should report the extra positional argument'
  assert_contains "$output" 'Usage: git-clean-branches [--yes] [--debug] [--] [remote]' 'should print usage on positional errors'
  assert_not_contains "$output" 'git should not run during argument parsing' 'should reject excess arguments before invoking git'
}

@test "accepts options after the positional remote before end-of-options" {
  create_repo_with_remote
  create_merged_remote_branch

  run_git_clean_branches_without_stdin "$REPO_DIR" origin --yes

  [ "$status" -eq 0 ] || fail 'documented option ordering should allow options after the remote'
  assert_contains "$output" 'Remote: origin' 'should use the selected remote'
  assert_branch_missing "$REPO_DIR" 'merged-remote' 'should honor --yes after the remote'
  assert_remote_branch_missing "$REMOTE_DIR" 'merged-remote' 'should delete remote branches when --yes follows the remote'
}

@test "end-of-options allows a dash-prefixed remote name" {
  create_repo_with_remote '--yes'

  run_git_clean_branches_without_stdin "$REPO_DIR" -- --yes

  [ "$status" -eq 0 ] || fail 'end-of-options should allow a dash-prefixed remote name'
  assert_contains "$output" 'Remote: --yes' 'should treat the token after -- as the remote name'
  assert_contains "$output" 'Nothing to delete.' 'should complete normally for the unusual remote'
}

@test "help and version succeed without a git repository" {
  local non_repo version

  non_repo="$TMP_HOME/non-repo"
  mkdir -p "$non_repo"
  version=$(tr -d '[:space:]' <"$REPO_ROOT/VERSION")

  run_git_clean_branches_without_stdin "$non_repo" --help
  [ "$status" -eq 0 ] || fail 'help should not require a git repository'
  assert_contains "$output" 'Usage: git-clean-branches [--yes] [--debug] [--] [remote]' 'help should show the updated synopsis'

  run_git_clean_branches_without_stdin "$non_repo" --version
  [ "$status" -eq 0 ] || fail 'version should not require a git repository'
  [ "$output" = "$version" ] || fail 'version should match the repository VERSION file'
}

@test "installed layout preserves focused option behavior" {
  local install_dir installed_tool non_repo version bin_dir

  install_dir="$TMP_HOME/install"
  installed_tool="$install_dir/bin/git-clean-branches"
  non_repo="$TMP_HOME/non-repo"
  bin_dir="$TMP_HOME/no-git-bin"
  mkdir -p "$non_repo" "$bin_dir"
  install_git_clean_branches_layout "$install_dir"
  version=$(tr -d '[:space:]' <"$REPO_ROOT/VERSION")
  cat >"$bin_dir/git" <<'EOF'
#!/usr/bin/env bash
printf 'git should not run during argument parsing\n' >&2
exit 99
EOF
  chmod +x "$bin_dir/git"

  run bash -c 'cd "$1" || exit 1; "$2" --help' _ "$non_repo" "$installed_tool"
  [ "$status" -eq 0 ] || fail 'installed help should not require a git repository'
  assert_contains "$output" 'Usage: git-clean-branches [--yes] [--debug] [--] [remote]' 'installed help should show the updated synopsis'

  run bash -c 'cd "$1" || exit 1; "$2" --version' _ "$non_repo" "$installed_tool"
  [ "$status" -eq 0 ] || fail 'installed version should not require a git repository'
  [ "$output" = "$version" ] || fail 'installed version should match VERSION'

  # shellcheck disable=SC2016
  run env PATH="$bin_dir:$PATH" bash -c 'cd "$1" || exit 1; "$2" --bogus </dev/null' _ "$non_repo" "$installed_tool"
  [ "$status" -eq 1 ] || fail 'installed unknown options should fail'
  assert_contains "$output" 'Error: unknown option: --bogus' 'installed parser should report unknown options'
  assert_not_contains "$output" 'git should not run during argument parsing' 'installed parser should reject before invoking git'
}

@test "direct parser returns explicit action options and remote" {
  local parsed_remote parsed_assume_yes parsed_action

  # shellcheck source=../tools/bin/git-clean-branches
  # shellcheck disable=SC1091
  source "$TOOL"

  debug_mode=false
  parse_git_clean_branches_args parsed_remote parsed_assume_yes parsed_action --debug upstream --yes

  [ "$parsed_remote" = upstream ] || fail 'parser should preserve the positional remote'
  [ "$parsed_assume_yes" = true ] || fail 'parser should preserve --yes'
  [ "$parsed_action" = run ] || fail 'parser should select the run action'
  [ "$debug_mode" = true ] || fail 'parser should set debug mode explicitly'

  parse_git_clean_branches_args parsed_remote parsed_assume_yes parsed_action -- --dash-remote

  [ "$parsed_remote" = --dash-remote ] || fail 'parser should preserve dash-prefixed remote after --'
  [ "$parsed_action" = run ] || fail 'parser should keep dash-prefixed remote as runnable input'
}

@test "direct planner keeps protected refs out and preserves candidate OIDs" {
  local discovered_local_refs=(refs/heads/main refs/heads/current refs/heads/worktree refs/heads/feature/slash.punct+one)
  local discovered_local_oids=(oid-main oid-current oid-worktree oid-local)
  local discovered_remote_refs=(refs/remotes/origin/HEAD refs/remotes/origin/main refs/remotes/origin/current refs/remotes/origin/feature/slash.punct+one)
  local discovered_remote_oids=(oid-head oid-main oid-current oid-remote)
  local worktree_branches=(worktree)
  local local_branch_refs=()
  local local_branch_oids=()
  local local_branch_names=()
  local remote_tracking_refs=()
  local remote_destination_refs=()
  local remote_branch_oids=()
  local remote_branch_names=()

  # shellcheck source=../tools/bin/git-clean-branches
  # shellcheck disable=SC1091
  source "$TOOL"

  collect_git_clean_branches_plan origin current main discovered_local_refs discovered_local_oids discovered_remote_refs discovered_remote_oids worktree_branches local_branch_refs local_branch_oids local_branch_names remote_tracking_refs remote_destination_refs remote_branch_oids remote_branch_names

  [ "${#local_branch_names[@]}" -eq 1 ] || fail 'planner should select one local candidate'
  [ "${local_branch_refs[0]}" = refs/heads/feature/slash.punct+one ] || fail 'planner should preserve local ref names'
  [ "${local_branch_oids[0]}" = oid-local ] || fail 'planner should preserve local OIDs'
  [ "${#remote_branch_names[@]}" -eq 1 ] || fail 'planner should select one remote candidate'
  [ "${remote_tracking_refs[0]}" = refs/remotes/origin/feature/slash.punct+one ] || fail 'planner should preserve remote tracking refs'
  [ "${remote_destination_refs[0]}" = refs/heads/feature/slash.punct+one ] || fail 'planner should render destination refs losslessly'
  [ "${remote_branch_oids[0]}" = oid-remote ] || fail 'planner should preserve remote OIDs'
}

@test "direct renderer prints reviewed plan and empty-plan status" {
  local local_branch_names=(local-one)
  local remote_branch_names=(remote-one)

  # shellcheck source=../tools/bin/git-clean-branches
  # shellcheck disable=SC1091
  source "$TOOL"

  run render_git_clean_branches_plan origin main current local_branch_names remote_branch_names
  [ "$status" -eq 0 ] || fail 'renderer should succeed when work is planned'
  assert_contains "$output" 'Remote: origin' 'renderer should print remote'
  assert_contains "$output" 'Local branches to delete:' 'renderer should print local section'
  assert_contains "$output" '  local-one' 'renderer should print local branch names'
  assert_contains "$output" 'Remote branches to delete:' 'renderer should print remote section'
  assert_contains "$output" '  remote-one' 'renderer should print remote branch names'

  local_branch_names=()
  remote_branch_names=()
  run render_git_clean_branches_plan origin main current local_branch_names remote_branch_names
  [ "$status" -eq 2 ] || fail 'empty renderer should return the empty-plan sentinel'
  assert_contains "$output" 'Nothing to delete.' 'renderer should explain empty plans'
}

@test "installed layout runs disposable repository smoke" {
  local install_dir installed_tool

  create_repo_with_remote
  install_dir="$TMP_HOME/install"
  installed_tool="$install_dir/bin/git-clean-branches"
  install_git_clean_branches_layout "$install_dir"

  run bash -c 'cd "$1" || exit 1; "$2" --yes' _ "$REPO_DIR" "$installed_tool"

  [ "$status" -eq 0 ] || fail 'installed tool should run against a disposable repository'
  assert_contains "$output" 'Remote: origin' 'installed smoke should load dependencies and inspect the repository'
  assert_contains "$output" 'Nothing to delete.' 'installed smoke should complete without mutating an empty plan'
}

@test "fails on detached HEAD" {
  create_repo_with_remote
  git -C "$REPO_DIR" checkout -q --detach HEAD

  run_git_clean_branches_without_stdin "$REPO_DIR" --yes

  [ "$status" -eq 1 ] || fail 'detached HEAD invocation should fail'
  assert_contains "$output" 'Error: detached HEAD is not supported' 'should explain detached HEAD is unsupported'
}

@test "fails when the remote default branch cannot be resolved" {
  create_repo_with_unresolved_default_remote

  run_git_clean_branches_without_stdin "$REPO_DIR" --yes

  [ "$status" -eq 1 ] || fail 'unresolved default branch should fail'
  assert_contains "$output" "Error: could not determine the default branch for remote 'origin'" 'should explain default branch resolution failure'
}

@test "reports an empty plan without prompting" {
  create_repo_with_remote

  run_git_clean_branches_without_stdin "$REPO_DIR"

  [ "$status" -eq 0 ] || fail 'empty plan should succeed'
  assert_contains "$output" 'Nothing to delete.' 'should report that there is no work to do'
}

@test "confirmation rejection performs no deletion" {
  create_repo_with_remote
  create_merged_remote_branch

  run_git_clean_branches "$REPO_DIR" 'n\n'

  [ "$status" -eq 1 ] || fail 'rejecting confirmation should fail'
  assert_contains "$output" 'Cancelled.' 'should report cancellation'
  assert_branch_exists "$REPO_DIR" 'merged-remote' 'should not delete local branches after rejection'
  assert_remote_branch_exists "$REMOTE_DIR" 'merged-remote' 'should not delete remote branches after rejection'
}

@test "confirmation EOF performs no deletion" {
  create_repo_with_remote
  create_merged_remote_branch

  run_git_clean_branches_without_stdin "$REPO_DIR"

  [ "$status" -eq 1 ] || fail 'EOF at confirmation should fail'
  assert_contains "$output" 'Cancelled.' 'should report cancellation at EOF'
  assert_branch_exists "$REPO_DIR" 'merged-remote' 'should not delete local branches after EOF'
  assert_remote_branch_exists "$REMOTE_DIR" 'merged-remote' 'should not delete remote branches after EOF'
}

@test "--yes executes the reviewed plan without reading stdin" {
  create_repo_with_remote
  create_merged_remote_branch

  run_git_clean_branches_without_stdin "$REPO_DIR" --yes

  [ "$status" -eq 0 ] || fail '--yes should not require confirmation input'
  assert_contains "$output" 'Local branches to delete:' 'should render the reviewed plan before deleting'
  assert_contains "$output" 'Remote branches to delete:' 'should render the reviewed plan before deleting'
  assert_contains "$output" 'Cleanup summary:' 'should print an outcome summary'
  assert_contains "$output" '  succeeded (2)' 'should account for local and remote success exactly once'
  assert_contains "$output" '  stale/skipped (0)' 'should report no stale operations on success'
  assert_contains "$output" '  failed (0)' 'should report no failed operations on success'
  assert_contains "$output" '  not attempted (0)' 'should report no unattempted operations on success'
  assert_branch_missing "$REPO_DIR" 'merged-remote' 'should delete local branches with --yes'
  assert_remote_branch_missing "$REMOTE_DIR" 'merged-remote' 'should delete remote branches with --yes'
}

@test "local transaction failure leaves every planned local ref unchanged" {
  local first_oid second_oid

  create_repo_with_remote
  create_unmerged_local_branch transaction-one
  create_unmerged_local_branch transaction-two
  first_oid=$(git -C "$REPO_DIR" rev-parse refs/heads/transaction-one)
  second_oid=$(git -C "$REPO_DIR" rev-parse refs/heads/transaction-two)
  install_git_clean_branches_failure_wrapper

  run_git_clean_branches_with_failure local-update-ref "$REPO_DIR" --yes

  [ "$status" -eq 1 ] || fail 'failed local transaction should fail the command'
  assert_contains "$output" 'Error: stale branch deletion plan: local branch refs changed during compare-and-swap deletion' 'should explain transaction failure'
  assert_contains "$output" '  failed (2)' 'should report both local refs as failed'
  assert_branch_exists "$REPO_DIR" transaction-one 'should preserve first local branch after transaction failure'
  assert_branch_exists "$REPO_DIR" transaction-two 'should preserve second local branch after transaction failure'
  [ "$(git -C "$REPO_DIR" rev-parse refs/heads/transaction-one)" = "$first_oid" ] || fail 'first branch OID should be unchanged'
  [ "$(git -C "$REPO_DIR" rev-parse refs/heads/transaction-two)" = "$second_oid" ] || fail 'second branch OID should be unchanged'
}

@test "multiple remote deletions use one atomic push" {
  local push_log push_count

  create_repo_with_remote
  create_merged_remote_branch atomic-one
  create_merged_remote_branch atomic-two
  git -C "$REPO_DIR" branch -D atomic-one >/dev/null
  git -C "$REPO_DIR" branch -D atomic-two >/dev/null
  push_log="$TMP_HOME/push.log"
  install_git_clean_branches_failure_wrapper

  run_git_clean_branches_with_push_log "$REPO_DIR" "$push_log" --yes

  [ "$status" -eq 0 ] || fail 'atomic remote deletion should succeed'
  push_count=$(wc -l <"$push_log")
  [ "$push_count" -eq 2 ] || fail 'should use exactly one dry-run push and one deletion push'
  assert_contains "$output" '  succeeded (2)' 'should report both remote refs as succeeded'
  assert_remote_branch_missing "$REMOTE_DIR" atomic-one 'should delete the first remote branch'
  assert_remote_branch_missing "$REMOTE_DIR" atomic-two 'should delete the second remote branch'
}

@test "unsupported atomic remote deletion fails before any mutation" {
  create_repo_with_remote
  create_merged_remote_branch no-atomic
  install_git_clean_branches_failure_wrapper

  run_git_clean_branches_with_failure remote-atomic-preflight "$REPO_DIR" --yes

  [ "$status" -eq 1 ] || fail 'unsupported atomic remote deletion should fail'
  assert_contains "$output" "Error: remote 'origin' does not support required atomic deletion; no branches were deleted" 'should explain the atomic remote requirement'
  assert_contains "$output" '  failed (1)' 'should report the remote operation as failed'
  assert_contains "$output" '  not attempted (1)' 'should report the local operation as not attempted'
  assert_branch_exists "$REPO_DIR" no-atomic 'should not delete local branches before remote atomic support is known'
  assert_remote_branch_exists "$REMOTE_DIR" no-atomic 'should not fall back to sequential remote deletion'
}

@test "failure between local and remote phases reports local success and remote not attempted" {
  create_repo_with_remote
  create_merged_remote_branch phase-stop

  run_git_clean_branches_with_failure between-local-and-remote "$REPO_DIR" --yes

  [ "$status" -eq 1 ] || fail 'injected phase failure should fail'
  assert_contains "$output" 'Error: injected failure between local and remote deletion phases' 'should explain phase failure'
  assert_contains "$output" '  succeeded (1)' 'should report the completed local deletion'
  assert_contains "$output" '  not attempted (1)' 'should report the unattempted remote deletion'
  assert_branch_missing "$REPO_DIR" phase-stop 'should leave completed local deletion in place'
  assert_remote_branch_exists "$REMOTE_DIR" phase-stop 'should not attempt remote deletion after phase failure'
}

@test "remote push failure after local completion reports exact outcomes without rollback claim" {
  create_repo_with_remote
  create_merged_remote_branch remote-fails

  run_git_clean_branches_with_failure remote-push "$REPO_DIR" --yes

  [ "$status" -eq 1 ] || fail 'injected remote push failure should fail'
  assert_contains "$output" 'Error: injected failure during remote branch push' 'should explain remote push failure'
  assert_contains "$output" '  succeeded (1)' 'should report the completed local deletion'
  assert_contains "$output" '  failed (1)' 'should report the failed remote deletion'
  assert_not_contains "$output" 'rolled back' 'should not claim rollback on remote failure'
  assert_branch_missing "$REPO_DIR" remote-fails 'should report local deletion as completed'
  assert_remote_branch_exists "$REMOTE_DIR" remote-fails 'should preserve the remote branch after injected push failure'
}

@test "fails closed when worktree discovery fails" {
  create_repo_with_remote
  create_merged_remote_branch
  install_git_clean_branches_failure_wrapper

  run_git_clean_branches_with_failure worktree-list "$REPO_DIR" --yes

  [ "$status" -eq 1 ] || fail 'worktree discovery failure should fail'
  assert_contains "$output" 'Error: failed to discover worktree branches' 'should explain worktree discovery failure'
  assert_not_contains "$output" 'branches to delete:' 'should not render an actionable deletion plan'
  assert_branch_exists "$REPO_DIR" 'merged-remote' 'should not delete local branches after worktree discovery failure'
  assert_remote_branch_exists "$REMOTE_DIR" 'merged-remote' 'should not delete remote branches after worktree discovery failure'
}

@test "fails closed when local branch discovery fails" {
  create_repo_with_remote
  create_merged_remote_branch
  install_git_clean_branches_failure_wrapper

  run_git_clean_branches_with_failure local-for-each-ref "$REPO_DIR" --yes

  [ "$status" -eq 1 ] || fail 'local discovery failure should fail'
  assert_contains "$output" 'Error: failed to discover local branches' 'should explain local discovery failure'
  assert_not_contains "$output" 'branches to delete:' 'should not render an actionable deletion plan'
  assert_branch_exists "$REPO_DIR" 'merged-remote' 'should not delete local branches after local discovery failure'
  assert_remote_branch_exists "$REMOTE_DIR" 'merged-remote' 'should not delete remote branches after local discovery failure'
}

@test "fails closed when remote branch discovery fails" {
  create_repo_with_remote
  create_merged_remote_branch
  install_git_clean_branches_failure_wrapper

  run_git_clean_branches_with_failure remote-for-each-ref "$REPO_DIR" --yes

  [ "$status" -eq 1 ] || fail 'remote discovery failure should fail'
  assert_contains "$output" 'Error: failed to discover remote branches' 'should explain remote discovery failure'
  assert_not_contains "$output" 'branches to delete:' 'should not render an actionable deletion plan'
  assert_branch_exists "$REPO_DIR" 'merged-remote' 'should not delete local branches after remote discovery failure'
  assert_remote_branch_exists "$REMOTE_DIR" 'merged-remote' 'should not delete remote branches after remote discovery failure'
}

@test "does not trust stale cached remote head when authoritative default resolution fails" {
  create_repo_with_remote
  create_merged_remote_branch
  install_git_clean_branches_failure_wrapper

  run_git_clean_branches_with_failure authoritative-default "$REPO_DIR" --yes

  [ "$status" -eq 1 ] || fail 'authoritative default failure should fail'
  assert_contains "$output" "Error: could not determine the default branch for remote 'origin'" 'should explain default resolution failure'
  assert_not_contains "$output" 'branches to delete:' 'should not render an actionable deletion plan'
  assert_branch_exists "$REPO_DIR" 'merged-remote' 'should not delete local branches when only cached remote HEAD is available'
  assert_remote_branch_exists "$REMOTE_DIR" 'merged-remote' 'should not delete remote branches when only cached remote HEAD is available'
}

@test "rejects stale plan when remote default changes before confirmation" {
  create_repo_with_remote
  create_merged_remote_branch
  create_remote_branch_at_main trunk

  run_git_clean_branches_with_delayed_default_change "$REPO_DIR" "$REMOTE_DIR" trunk

  [ "$status" -eq 1 ] || fail 'changed default branch should fail before deletion'
  assert_contains "$output" "Error: default branch changed from 'main' to 'trunk'; refusing stale deletion plan" 'should explain stale default plan'
  assert_branch_exists "$REPO_DIR" 'merged-remote' 'should not delete local branches after default changes'
  assert_remote_branch_exists "$REMOTE_DIR" 'merged-remote' 'should not delete remote branches after default changes'
}

@test "rejects stale plan when the remote default branch OID moves before deletion" {
  create_repo_with_remote
  create_merged_remote_branch default-rewind

  run_git_clean_branches_with_delayed_remote_default_rewind "$REPO_DIR" "$REMOTE_DIR" main

  [ "$status" -eq 1 ] || fail 'moved remote default OID should fail before deletion'
  assert_contains "$output" "Error: stale branch deletion plan: remote default branch 'origin/main' moved since the plan was reviewed" 'should explain stale remote default OID'
  assert_branch_exists "$REPO_DIR" default-rewind 'should not delete local branches after remote default moves'
  assert_remote_branch_exists "$REMOTE_DIR" default-rewind 'should not delete remote branches after remote default moves'
}

@test "rejects stale plan when a local branch advances before deletion" {
  local old_oid new_oid

  create_repo_with_remote
  create_unmerged_local_branch stale-local
  old_oid=$(git -C "$REPO_DIR" rev-parse refs/heads/stale-local)

  run_git_clean_branches_with_delayed_local_advance "$REPO_DIR" stale-local

  [ "$status" -eq 1 ] || fail 'advanced local branch should fail before deletion'
  assert_contains "$output" "Error: stale branch deletion plan: local branch 'stale-local' moved since the plan was reviewed" 'should explain stale local branch'
  assert_branch_exists "$REPO_DIR" stale-local 'should preserve the advanced local branch'
  new_oid=$(git -C "$REPO_DIR" rev-parse refs/heads/stale-local)
  [ "$new_oid" != "$old_oid" ] || fail 'local branch should remain at the advanced OID'
}

@test "rejects remote deletion with an explicit lease when a second clone advances the branch" {
  local old_oid new_oid

  create_repo_with_remote
  create_merged_remote_branch lease-remote
  old_oid=$(git -C "$REMOTE_DIR" rev-parse refs/heads/lease-remote)
  git -C "$REPO_DIR" branch -D lease-remote >/dev/null

  run_git_clean_branches_with_delayed_remote_advance "$REPO_DIR" "$REMOTE_DIR" lease-remote

  [ "$status" -eq 1 ] || fail 'advanced remote branch should fail by lease before deletion'
  assert_contains "$output" "Error: stale branch deletion plan: remote branch 'origin/lease-remote' moved since the plan was reviewed" 'should explain stale remote branch'
  assert_remote_branch_exists "$REMOTE_DIR" lease-remote 'should preserve the advanced remote branch'
  new_oid=$(git -C "$REMOTE_DIR" rev-parse refs/heads/lease-remote)
  [ "$new_oid" != "$old_oid" ] || fail 'remote branch should remain at the second clone OID'
}

@test "rejects stale plan when a local candidate is checked out in another worktree before preflight" {
  local worktree_dir

  create_repo_with_remote
  create_unmerged_local_branch worktree-late
  worktree_dir="$TMP_HOME/worktrees/worktree-late"

  run_git_clean_branches_with_delayed_worktree_checkout "$REPO_DIR" worktree-late "$worktree_dir"

  [ "$status" -eq 1 ] || fail 'late worktree checkout should fail before deletion'
  assert_contains "$output" "Error: stale branch deletion plan: local branch 'worktree-late' is checked out in another worktree" 'should explain late worktree protection'
  assert_branch_exists "$REPO_DIR" worktree-late 'should preserve the branch held by another worktree'
}

@test "reports stale plan when a local candidate is deleted before preflight" {
  create_repo_with_remote
  create_unmerged_local_branch deleted-local

  run_git_clean_branches_with_delayed_local_delete "$REPO_DIR" deleted-local

  [ "$status" -eq 1 ] || fail 'deleted local candidate should be reported as stale'
  assert_contains "$output" "Error: stale branch deletion plan: local branch 'deleted-local' no longer exists" 'should explain missing local branch'
}

@test "reports stale plan when a remote candidate is deleted before leased deletion" {
  create_repo_with_remote
  create_merged_remote_branch deleted-remote
  git -C "$REPO_DIR" branch -D deleted-remote >/dev/null

  run_git_clean_branches_with_delayed_remote_delete "$REPO_DIR" "$REMOTE_DIR" deleted-remote

  [ "$status" -eq 1 ] || fail 'deleted remote candidate should be reported as stale'
  assert_contains "$output" "Error: stale branch deletion plan: remote branch 'origin/deleted-remote' no longer exists" 'should explain missing remote branch'
  assert_remote_branch_missing "$REMOTE_DIR" deleted-remote 'should leave the independently deleted remote branch missing'
}

@test "deletes valid ref names with slashes punctuation and a leading dash through guarded refs" {
  local punctuation_branch="feature/slash.\$dollar;plus+equals=comma,percent%"
  local leading_dash_branch='-dash-cleanup'
  local main_oid

  create_repo_with_remote
  main_oid=$(git -C "$REPO_DIR" rev-parse refs/heads/main)
  git -C "$REPO_DIR" update-ref "refs/heads/$punctuation_branch" "$main_oid"
  git -C "$REPO_DIR" update-ref "refs/heads/$leading_dash_branch" "$main_oid"
  git -C "$REPO_DIR" push -q origin "refs/heads/$punctuation_branch:refs/heads/$punctuation_branch"
  git -C "$REPO_DIR" push -q origin "refs/heads/$leading_dash_branch:refs/heads/$leading_dash_branch"

  run_git_clean_branches_without_stdin "$REPO_DIR" --yes

  [ "$status" -eq 0 ] || fail 'guarded deletion should handle shell-significant and leading-dash ref names'
  assert_contains "$output" "  $punctuation_branch" 'should display the punctuation branch name'
  assert_contains "$output" "  $leading_dash_branch" 'should display the leading-dash branch name'
  assert_branch_missing "$REPO_DIR" "$punctuation_branch" 'should delete punctuation local refs through full ref names'
  assert_branch_missing "$REPO_DIR" "$leading_dash_branch" 'should delete leading-dash local refs through full ref names'
  assert_remote_branch_missing "$REMOTE_DIR" "$punctuation_branch" 'should delete punctuation remote refs through full refspecs'
  assert_remote_branch_missing "$REMOTE_DIR" "$leading_dash_branch" 'should delete leading-dash remote refs through full refspecs'
}

@test "cleans branches for a custom remote with fresh authoritative default evidence" {
  create_repo_with_remote upstream
  create_merged_remote_branch

  run_git_clean_branches_without_stdin "$REPO_DIR" --yes upstream

  [ "$status" -eq 0 ] || fail 'custom remote cleanup should succeed'
  assert_contains "$output" 'Remote: upstream' 'should render the selected custom remote'
  assert_contains "$output" 'Remote branches to delete:' 'should render remote branch plan for custom remote'
  assert_remote_branch_missing "$REMOTE_DIR" 'merged-remote' 'should delete merged branches from the selected remote'
}

@test "falls back to main only with fresh remote evidence" {
  local main_oid

  create_repo_with_remote
  main_oid=$(git -C "$REMOTE_DIR" rev-parse refs/heads/main)
  printf '%s\n' "$main_oid" >"$REMOTE_DIR/HEAD"

  run_git_clean_branches_without_stdin "$REPO_DIR" --yes

  [ "$status" -eq 0 ] || fail 'fresh main fallback should succeed'
  assert_contains "$output" 'Default branch: main' 'should use main as the fallback default branch'
  assert_contains "$output" 'Nothing to delete.' 'should complete normally with fallback evidence'
}

@test "skips local branches that are checked out in another worktree" {
  local worktree_dir

  create_repo_with_remote
  checkout_topic_branch

  git -C "$REPO_DIR" branch dv main
  git -C "$REPO_DIR" branch feat/git-context main
  worktree_dir="$TMP_HOME/worktrees/git-context"
  mkdir -p "$TMP_HOME/worktrees"
  git -C "$REPO_DIR" worktree add -q "$worktree_dir" feat/git-context

  run_git_clean_branches_without_stdin "$REPO_DIR" --debug --yes

  [ "$status" -eq 0 ] || fail 'cleaning branches should succeed when another worktree exists'
  assert_contains "$output" "[git-clean-branches] Cleaning branches against remote 'origin'" 'debug mode should identify the selected remote'
  assert_contains "$output" 'Local branches to delete:' 'should still delete other local branches'
  assert_contains "$output" '  dv' 'should include deletable local branches'
  assert_not_contains "$output" '  feat/git-context' 'should skip branches used by another worktree'
  assert_branch_missing "$REPO_DIR" 'dv' 'should delete local branches not used by a worktree'
  assert_branch_exists "$REPO_DIR" 'feat/git-context' 'should preserve branches checked out in another worktree'
}

@test "help documents debug mode" {
  run "$TOOL" --help

  [ "$status" -eq 0 ] || fail 'git-clean-branches --help should succeed'
  assert_contains "$output" '--debug' 'help should list debug mode'
}
