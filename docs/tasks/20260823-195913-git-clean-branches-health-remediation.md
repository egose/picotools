# Git Clean Branches Health Remediation

Created: 2026-08-23 19:59:13 -0700

## Objective

Make `git-clean-branches` fail closed while discovering and deleting refs, prevent branches from being deleted after they change from the reviewed plan, define partial-failure behavior, and improve readability, encapsulation, reuse, testability, documentation, and measured performance without weakening its current branch protections.

## Scope

- `tools/bin/git-clean-branches`
- `tests/git-clean-branches.bats` and new focused `tests/git-clean-branches-*.bats` files
- A cohesive tool-specific module under `tools/lib/picotools/git-clean-branches/` only if direct testing justifies extraction
- `lib/picotools/git.sh` and its consumers/tests only if the shared default-branch contract is changed
- `README.md`, `package.json`, and `.github/workflows/test.yml`

## Working Rules And Non-Goals

- Inspect `git status --short` before each task. Preserve unrelated concurrent changes and never revert another agent's work.
- Serialize tasks that modify `tools/bin/git-clean-branches` or `tests/git-clean-branches.bats`; split stable test ownership before parallel work.
- Add a failing regression before each confirmed behavior fix. Tests for destructive behavior must use disposable local repositories and bare remotes under Bats-owned temporary directories.
- Treat ref names, object IDs, remote metadata, worktree output, network responses, and user arguments as untrusted input. Quoting alone does not terminate Git option parsing.
- Preserve the intentional contract that every unprotected local branch is force-deleted even when unmerged. Do not silently change local cleanup to merged-only behavior.
- Preserve default-branch, current-branch, symbolic remote-HEAD, and linked-worktree protections. Revalidate protections immediately before mutation rather than trusting only the displayed plan.
- Do not add rollback that rewrites commits or recreates refs at potentially stale object IDs. Prefer atomic compare-and-swap operations and precise outcome reporting.
- Follow `.opencode/skills/bash-tool-conventions/SKILL.md`: keep direct shared-module declarations, installed-layout loading, standard flags, two-space formatting, and focused Bats coverage.
- Avoid a generic branch-management framework. Extract only stable planning/application boundaries required for isolated tests or reuse.
- Retain performance changes only when a reproducible benchmark shows a material improvement.

## Confirmed Baseline

- The executable is 183 lines. `main` owns option parsing, repository and remote validation, fetch/default resolution, worktree discovery, candidate planning, rendering, confirmation, and destructive application (`tools/bin/git-clean-branches:48-181`).
- Candidate arrays contain branch names but not their reviewed object IDs. Local branches are later force-deleted and remote branches are later deleted without compare-and-swap protection (`tools/bin/git-clean-branches:107-146`, `tools/bin/git-clean-branches:172-180`). A ref that advances while confirmation is pending can therefore be deleted even though the user never reviewed its new state.
- All three discovery producers run in process substitutions attached to `while` loops. A producer failure does not become the loop's status under `set -e`, so failed worktree or ref discovery can produce an incomplete plan or `Nothing to delete` rather than aborting (`tools/bin/git-clean-branches:112-146`).
- Default-branch resolution suppresses failure from `git remote set-head --auto` and then accepts an existing symbolic remote HEAD. A stale cached symbolic ref can protect the wrong branch during destructive cleanup (`lib/picotools/git.sh:23-55`). The helper is also used by `tools/bin/git-clean-task-pr:233`, so a shared behavior change requires compatibility tests.
- Destructive operations are sequential. The first failed local or remote deletion exits through `set -e` after earlier operations may already have succeeded, with no applied/failed/skipped summary (`tools/bin/git-clean-branches:172-180`).
- Unrecognized options are accepted as the positional remote, there is no `--` terminator, and the synopsis omits the supported `--debug` flag (`tools/bin/git-clean-branches:16`, `tools/bin/git-clean-branches:54-80`).
- The symbolic remote-HEAD test asserts that `origin` is absent, but the accidental candidate would render as `HEAD`; removing the production filter would not make that assertion fail (`tests/git-clean-branches.bats:99-110`).
- Worktree exclusion scans the complete worktree branch array for every local branch, and remote deletion launches one push per branch (`tools/bin/git-clean-branches:120-146`, `tools/bin/git-clean-branches:172-180`). This is a plausible scale cost, not yet a measured production problem.
- The focused suite contains only three scenarios and does not exercise successful remote deletion, unmerged-branch contracts, default/current protections, discovery failures, moved refs, parser errors, confirmation EOF, or mid-application failures (`tests/git-clean-branches.bats:99-140`).
- `npm run check:syntax` includes only `tests/git-commit*.bats`, so this Bats file and other non-commit suites are omitted from that configured check (`package.json:15-24`). ShellCheck already covers all Bats files (`scripts/shellcheck.bash:5-13`).
- README coverage does not state that local deletion is forced even for unmerged branches, that the command fetches with prune, how worktrees are protected, or what happens after a partial failure (`README.md:28`, `README.md:89`).
- Worktree at review time was clean (`git status --short` produced no output).

## Baseline Verification

Run on 2026-08-23 before creating this task:

- `bats tests/git-clean-branches.bats`: 3 passed.
- `bash -n tools/bin/git-clean-branches tests/git-clean-branches.bats lib/picotools/git.sh`: passed.
- `shellcheck -s bash -x tools/bin/git-clean-branches tests/git-clean-branches.bats lib/picotools/git.sh`: passed.
- `scripts/shfmt-diff.bash`: passed with no diff.
- `git diff --check`: passed.
- Full `npm test`, installed-archive tests, and `pre-commit run --all-files` were not run because this review only creates a task document.

## Priorities

- P0: A confirmed path that can delete a ref whose current object was not in the confirmed plan.
- P1: Confirmed fail-open discovery, stale protection, or partial destructive-operation defects; tests that falsely claim to guard those boundaries.
- P2: CLI correctness, architecture, testability, documentation, packaging, and CI gaps.
- P3: Optional performance work requiring benchmark evidence.

## Required Verification Ladder

Every implementation task must record changed files, failing-before/passing-after regressions, command output summaries, and follow-up findings in a `Completion evidence` block. A task is complete only when its focused tests and applicable checks pass or an exact blocker is recorded.

1. Focused tests: `bats tests/git-clean-branches*.bats`, using `npm run test:git-clean-branches` after TEST-01 adds it.
2. Syntax: `bash -n tools/bin/git-clean-branches lib/picotools/git.sh tools/lib/picotools/git-clean-branches/*.sh tests/helpers/git-clean-branches.bash tests/git-clean-branches*.bats`, limited to paths that exist.
3. Static checks: `shellcheck -s bash -x` on every changed shell/Bats file, `scripts/shfmt-diff.bash`, and `git diff --check`.
4. Focused pre-commit: `pre-commit run --files <all files changed by the task>`.
5. Shared helper compatibility: `bats tests/git-clean-task-pr.bats tests/git-clean-branches*.bats` whenever `lib/picotools/git.sh` changes.
6. Final integration only: `npm test`, `npm run check:syntax`, `npm run check:shellcheck`, `npm run check:format`, `pre-commit run --all-files`, and the installed-archive smoke path from `.github/workflows/test.yml`.

## Wave 1: Trustworthy Regression Harness

### Task TEST-01: Establish Destructive-Boundary Regression Coverage

Status: completed

Priority: P1

Suggested agent: Bats and Git fixture engineer

Dependencies: none

Primary ownership:

- `tests/git-clean-branches.bats`
- New `tests/helpers/git-clean-branches.bash`
- `package.json`

Finding:

The focused suite has three scenarios. Its symbolic remote-HEAD assertion checks for `origin`, although the production parser would render the symbolic candidate as `HEAD`, so the test does not detect removal of the filter it names. The suite lacks direct coverage for nearly every destructive and fail-closed contract.

References:

- `tests/git-clean-branches.bats:1-140`
- `tests/git-clean-branches.bats:99-110`
- `tools/bin/git-clean-branches:137-146`
- `package.json:15-24`

Implementation requirements:

1. Correct the symbolic remote-HEAD test to inspect the remote-candidate section and reject a standalone `HEAD` entry; prove the regression fails when the production filter is disabled.
2. Extract reusable disposable repository, bare-remote, branch, worktree, assertion, and Git-wrapper helpers only where this reduces duplication.
3. Add baseline behavior tests for successful merged remote deletion, preservation of an unmerged remote branch, forced deletion of an unmerged local branch, and preservation of default/current/worktree branches.
4. Add baseline error tests for a missing remote, non-repository directory, detached HEAD, unresolved default branch, empty plan, confirmation yes/no/EOF, and `--yes` bypass.
5. Capture command arguments losslessly in stubs. Do not flatten refspecs or branch names through `$*`.
6. Add `test:git-clean-branches` to run all focused files without removing `npm test` compatibility.
7. Do not encode the current unsafe moved-ref or ignored-discovery-failure behavior as a desired assertion; those regressions belong to SAFE-01 and DISC-01.

Acceptance criteria:

- The corrected symbolic-HEAD test fails if the production `refs/remotes/<remote>/HEAD` exclusion is removed.
- Tests prove the current documented distinction between force-deleting local branches and deleting only merged remote branches.
- Default, current, linked-worktree, and symbolic remote-HEAD protections each have an observable regression.
- Confirmation rejection and EOF perform no deletion; `--yes` executes the same reviewed plan without reading stdin.
- `npm run test:git-clean-branches` runs every `tests/git-clean-branches*.bats` file and passes.

Completion evidence:

- Changed files: `tests/git-clean-branches.bats`, `tests/helpers/git-clean-branches.bash`, `package.json`, `docs/tasks/20260823-195913-git-clean-branches-health-remediation.md`.
- Regression coverage: symbolic remote `HEAD` is asserted inside the remote-candidate section as not being a standalone `HEAD`; merged remote deletion, unmerged remote preservation, unmerged local force-deletion, and default/current/worktree protections are covered with disposable real Git repositories.
- Error and confirmation coverage: missing remote, non-repository invocation, detached HEAD, unresolved default branch, empty plan, yes/no/EOF confirmation behavior, and `--yes` stdin bypass are covered.
- Stub coverage: no command stubs were introduced; all destructive-boundary assertions use real disposable local and bare Git repositories.
- Command summaries: `npm run test:git-clean-branches` passed; `bash -n tools/bin/git-clean-branches tests/helpers/git-clean-branches.bash tests/git-clean-branches.bats` passed; `git diff --check` passed; focused `pre-commit run --files package.json tests/git-clean-branches.bats tests/helpers/git-clean-branches.bash docs/tasks/20260823-195913-git-clean-branches-health-remediation.md` passed.
- Follow-ups/blockers: none for TEST-01; no unsafe moved-ref or ignored-discovery-failure behavior was encoded.

## Wave 2: Fail-Closed Discovery And Conditional Deletion

### Task DISC-01: Make Candidate Discovery And Default Resolution Fail Closed

Status: completed

Priority: P1

Suggested agent: Bash and Git metadata boundary engineer

Dependencies: TEST-01

Primary ownership:

- `tools/bin/git-clean-branches`
- Focused discovery tests
- `lib/picotools/git.sh` only if the shared contract is deliberately changed
- `tests/git-clean-task-pr.bats` if the shared helper changes

Finding:

Worktree, local-ref, and remote-ref commands run inside process substitutions whose exit statuses are not propagated by the consuming loops. Default resolution also ignores authoritative refresh failure and may accept stale cached remote-HEAD metadata. In a destructive command, incomplete worktree data or a stale default can make a protected branch eligible.

References:

- `tools/bin/git-clean-branches:97-146`
- `lib/picotools/git.sh:23-55`
- Shared consumer: `tools/bin/git-clean-task-pr:233`

Implementation requirements:

1. Capture each discovery command's output and status before parsing, using a lossless representation for ref names. Abort before rendering, prompting, or deleting when any discovery command fails.
2. Resolve the remote default branch authoritatively for this destructive operation. Do not silently use a stale symbolic ref after refresh/query failure.
3. Validate that the resolved default exists in the selected remote namespace and is usable as the merge boundary before candidate collection.
4. Re-resolve the authoritative default immediately before application and reject the plan if it changed or became unavailable.
5. Keep the stricter contract tool-local unless a shared-helper change is demonstrably safe. If `picotools_git_default_branch` changes, preserve or deliberately update `git-clean-task-pr` behavior with tests.
6. Return failures from newly reusable functions; keep final process exit in command orchestration.

Acceptance criteria:

- Injected failures from `git worktree list`, local `git for-each-ref`, remote `git for-each-ref`, and authoritative default resolution each return nonzero before outputting an actionable deletion plan or invoking a delete.
- A stale cached `refs/remotes/<remote>/HEAD` is not trusted when authoritative resolution fails.
- A default branch that changes while confirmation is pending causes a stale-plan error and no deletion.
- Valid repositories retain current custom-remote, symbolic-HEAD, and fallback behavior only where that behavior has fresh authoritative evidence.
- Focused tests and `tests/git-clean-task-pr.bats` pass when shared code is touched.

Completion evidence:

- Changed files: `tools/bin/git-clean-branches`, `tests/git-clean-branches.bats`, `tests/helpers/git-clean-branches.bash`, `docs/tasks/20260823-195913-git-clean-branches-health-remediation.md`.
- Regression coverage: injected failures from `git worktree list`, local `git for-each-ref`, remote `git for-each-ref`, and authoritative default lookup each fail before rendering branch deletion sections or deleting refs; stale cached `refs/remotes/origin/HEAD` is rejected when fresh default lookup fails; default changes during confirmation reject the stale plan without deleting; custom remote and fresh `main` fallback behavior remain covered.
- Implementation summary: `git-clean-branches` now resolves default branch tool-locally from fresh `git ls-remote --symref <remote> HEAD` evidence, falls back to `main` only after a fresh remote heads query, validates `refs/remotes/<remote>/<default>` as a local commit merge boundary before remote candidate collection, captures discovery command output/status before parsing, and re-resolves/validates the default immediately before deletion.
- Command summaries: initial `npm run test:git-clean-branches` failed for newly added regressions until the failure wrapper exported the real Git path and the stale-default runner changed the remote before confirmation; subsequent `npm run test:git-clean-branches` passed with 22 tests. `bash -n tools/bin/git-clean-branches tests/helpers/git-clean-branches.bash tests/git-clean-branches.bats` passed. `shellcheck -s bash -x tools/bin/git-clean-branches tests/helpers/git-clean-branches.bash tests/git-clean-branches.bats` passed after replacing Bats subshell exports with a runner helper. `scripts/shfmt-diff.bash` passed. `git diff --check` passed. Focused `pre-commit run --files tools/bin/git-clean-branches tests/git-clean-branches.bats tests/helpers/git-clean-branches.bash docs/tasks/20260823-195913-git-clean-branches-health-remediation.md` passed.
- Follow-ups/blockers: `lib/picotools/git.sh` was not changed, so `tests/git-clean-task-pr.bats` compatibility verification was not applicable; compare-and-swap deletion races remain for SAFE-01.

### Task SAFE-01: Apply The Reviewed Ref Snapshot With Compare-And-Swap Guards

Status: completed

Priority: P0

Suggested agent: Git refs and concurrency engineer

Dependencies: DISC-01

Primary ownership:

- Candidate plan and apply behavior in `tools/bin/git-clean-branches`
- Focused stale-plan and ref-name tests
- Tool-specific core module if introduced

Finding:

The displayed plan stores only branch names. After an arbitrarily long confirmation wait, local deletion uses `git branch -D` and remote deletion uses an unconditional push. If either ref advances after discovery, the unseen commits are deleted.

References:

- `tools/bin/git-clean-branches:107-146`
- `tools/bin/git-clean-branches:148-170`
- `tools/bin/git-clean-branches:172-180`

Implementation requirements:

1. Store each candidate as a validated full ref name plus its observed object ID; do not serialize name/OID pairs through ambiguous delimiter-separated text.
2. Immediately before mutation, revalidate current branch, all worktree-held branches, default branch, candidate existence, candidate OIDs, and the remote merge condition used to select remote candidates.
3. Delete local refs through an expected-old-OID compare-and-swap operation. Investigate and test whether the selected plumbing enforces linked-worktree occupancy; if Git offers no primitive that atomically combines both guards, minimize and document the residual worktree-attachment race rather than claiming a guarantee the client cannot provide.
4. Delete remote refs with full destination refspecs and explicit leases tied to the reviewed remote OIDs. Never rely on ambient tracking-ref state as an implicit lease.
5. Use `--` or unambiguous full refs/refspecs at every Git operand boundary. Cover valid refs with slashes and punctuation, including plumbing-created leading-dash names where Git permits them.
6. Treat a missing or moved candidate as stale rather than success. Abort or skip according to STATE-01's explicit all-or-nothing contract, never silently delete the replacement object.
7. Preserve the displayed branch names and intentional force-delete-local/unmerged contract.

Acceptance criteria:

- A local branch advanced while confirmation is pending remains at its new OID and the command reports a stale plan.
- A remote branch advanced by a second clone while confirmation is pending is rejected by an explicit lease and remains on the remote.
- A branch checked out in another worktree before final preflight is preserved; any unavoidable race after that check is characterized and documented from a reproducible test.
- A candidate deleted by another process is reported deterministically and cannot cause a different ref to be deleted.
- Ref names with slashes, valid shell-significant punctuation, and a leading dash where valid are passed as single non-option operands.
- No destructive command applies an object ID or protected-ref set different from the confirmed snapshot.

Completion evidence:

- Changed files: `tools/bin/git-clean-branches`, `tests/git-clean-branches.bats`, `tests/helpers/git-clean-branches.bash`, `docs/tasks/20260823-195913-git-clean-branches-health-remediation.md`.
- Regression coverage: local branch advance during confirmation is rejected as stale and preserves the new OID; remote branch advance from a second clone is rejected by `--force-with-lease=<full-dst-ref>:<reviewed-oid>` and remains on the remote; a branch checked out in another worktree before final preflight is preserved; local and remote candidates deleted during confirmation are reported stale; slash, shell-significant punctuation, and plumbing-created leading-dash refs are deleted through full refs/refspecs without option ambiguity.
- Implementation summary: candidate plans now store branch display names separately from validated full local/tracking/destination refs and reviewed OID arrays; final preflight revalidates current branch, linked worktree branches, default branch, local candidate existence/OIDs, remote tracking candidate existence/OIDs, and the remote merge condition; local deletion uses an `update-ref --stdin` transaction with expected old OIDs; remote deletion uses full destination refspecs plus explicit leases tied to reviewed OIDs.
- Residual race: `git update-ref -d <ref> <old-oid>` provides the local compare-and-swap guard but does not reject a branch checked out in a linked worktree. The tool performs a final `git worktree list --porcelain` preflight immediately before the `update-ref` transaction; a branch checked out after that preflight but before the transaction remains an unavoidable Git-client race for SAFE-01 and is documented in code.
- Command summaries: `npm run test:git-clean-branches` passed with 28 tests. `bash -n tools/bin/git-clean-branches tests/helpers/git-clean-branches.bash tests/git-clean-branches.bats` passed. `shellcheck -s bash -x tools/bin/git-clean-branches tests/helpers/git-clean-branches.bash tests/git-clean-branches.bats` passed. `scripts/shfmt-diff.bash` passed. `git diff --check` passed. Focused `pre-commit run --files tools/bin/git-clean-branches tests/git-clean-branches.bats tests/helpers/git-clean-branches.bash docs/tasks/20260823-195913-git-clean-branches-health-remediation.md` passed.
- Follow-ups/blockers: no blocker for SAFE-01; STATE-01 still owns all-or-nothing cleanup outcome semantics across mixed local/remote failures.

### Task STATE-01: Define Atomicity And Report Every Cleanup Outcome

Status: completed

Priority: P1

Suggested agent: Git transaction and CLI recovery engineer

Dependencies: SAFE-01

Primary ownership:

- Apply and result-reporting behavior in `tools/bin/git-clean-branches`
- Focused transaction/failure tests
- Help and README failure contract touched with DOC-CI-01 coordination

Finding:

Local and remote deletes run sequentially under `set -e`. A failure exits after prior refs have been removed, without identifying which operations succeeded, failed, or were not attempted. One push per remote branch also increases network round trips and broadens the race window.

References:

- `tools/bin/git-clean-branches:172-180`
- `README.md:89`

Implementation requirements:

1. Preflight every local and remote candidate before any mutation and reject a stale plan as a unit.
2. Apply local compare-and-swap deletions in one Git ref transaction when supported by the repository's minimum Git version.
3. Send remote deletions in one push with per-ref explicit leases. Request atomic push when the remote supports it.
4. Preflight required remote atomic-push capability before the local transaction where Git permits a side-effect-free check. Use the safe default in Deferred Decisions: if atomic remote deletion is unsupported, fail before any mutation rather than silently falling back to sequential partial deletion. A network or remote failure after local completion must still be documented and reported precisely.
5. Capture command statuses explicitly rather than depending on `set -e` for user-facing recovery behavior.
6. Print a bounded summary of succeeded, stale/skipped, failed, and not-attempted operations. Do not claim rollback when none occurred.
7. Add deterministic failure injection before local transaction, between local and remote phases, and at remote push.

Acceptance criteria:

- A local transaction failure leaves every planned local ref unchanged.
- Multiple remote deletions use one push and are all applied or all rejected on an atomic-capable bare remote.
- Unsupported atomic remote behavior fails according to the documented contract without sequential deletion.
- Failures after local completion report the exact local success and every remote ref as failed or not attempted.
- Success output accounts for every planned candidate exactly once.
- No failure path emits a misleading unconditional success message.

Completion evidence:

- Changed files: `tools/bin/git-clean-branches`, `tests/git-clean-branches.bats`, `tests/helpers/git-clean-branches.bash`, `docs/tasks/20260823-195913-git-clean-branches-health-remediation.md`.
- Regression coverage: local `update-ref --stdin` transaction failure preserves all planned local refs and reports them failed; multiple remote refs are deleted through one non-dry-run atomic push with explicit per-ref leases; unsupported atomic remote preflight fails before local mutation; injected failures between local/remote phases and at remote push report exact succeeded, failed, and not-attempted outcomes without claiming rollback; success output accounts for each planned local/remote operation exactly once.
- Implementation summary: deletion now initializes explicit per-operation outcomes, reruns local/tracking preflight, verifies actual remote head OIDs with `git ls-remote --heads`, dry-runs a leased `git push --atomic` before local mutation, deletes local refs through the existing single `update-ref --stdin` transaction, deletes all remote refs with one leased `--atomic` push, and prints a bounded cleanup summary for success and apply/preflight failures.
- Command summaries: `npm run test:git-clean-branches` passed with 33 tests. `bash -n tools/bin/git-clean-branches tests/helpers/git-clean-branches.bash tests/git-clean-branches.bats` passed. `shellcheck -s bash -x tools/bin/git-clean-branches tests/helpers/git-clean-branches.bash tests/git-clean-branches.bats` passed. `scripts/shfmt-diff.bash` passed. `git diff --check` passed. Focused `pre-commit run --files tools/bin/git-clean-branches tests/git-clean-branches.bats tests/helpers/git-clean-branches.bash docs/tasks/20260823-195913-git-clean-branches-health-remediation.md` passed.
- Follow-ups/blockers: no blockers for STATE-01. README/help failure-contract wording remains under DOC-CI-01 coordination and was not edited here to keep the task isolated.

## Wave 3: CLI, Encapsulation, And Maintainability

### Task CLI-01: Make Argument Parsing Explicit And Unambiguous

Status: completed

Priority: P2

Suggested agent: Bash CLI contract engineer

Dependencies: TEST-01

Primary ownership:

- Option parsing and usage in `tools/bin/git-clean-branches`
- Focused option tests

Finding:

Every unrecognized token is treated as the optional remote until one positional is set. Consequently, `--bogus` produces a missing-remote error instead of an unknown-option error, and there is no `--` terminator. The usage synopsis omits `--debug`.

References:

- `tools/bin/git-clean-branches:14-29`
- `tools/bin/git-clean-branches:48-80`

Implementation requirements:

1. Reject unknown `-*` options with a concise diagnostic and usage on stderr.
2. Support `--` as the end-of-options marker while retaining exactly zero or one positional remote.
3. Preserve `-h`/`--help`/`help`, `-v`/`--version`/`version`, `--yes`, and `--debug` behavior in source and installed layouts.
4. Update the synopsis to `[--yes] [--debug] [--] [remote]` or an equivalent accurate form.
5. Keep parsing free of repository or network side effects so it can be tested directly.

Acceptance criteria:

- Unknown options fail as options before any Git command runs.
- Excess positional arguments fail consistently.
- Options before and after a positional follow one documented rule, and `--` allows a valid unusual remote name where Git supports it.
- Help and version retain status zero without requiring a repository.
- Focused option tests pass in repository and installed layouts.

Completion evidence:

- Changed files: `tools/bin/git-clean-branches`, `tests/git-clean-branches.bats`, `tests/helpers/git-clean-branches.bash`, `docs/tasks/20260823-195913-git-clean-branches-health-remediation.md`.
- Regression coverage: unknown `-*` options fail with usage before Git runs; excess positional arguments fail before Git runs; documented option ordering accepts known options before or after the positional remote until `--`; `--` treats following dash-prefixed tokens as the optional remote; help/version succeed without a repository; installed-layout help/version/unknown-option parser paths are covered.
- Implementation summary: parser now tracks an explicit end-of-options state, rejects unknown dash-prefixed options, keeps the zero-or-one remote limit, documents `[--yes] [--debug] [--] [remote]`, and uses Git `--` separators for remote commands needed by dash-prefixed remote names.
- Command summaries: `npm run test:git-clean-branches` passed with 39 tests. `bash -n tools/bin/git-clean-branches tests/helpers/git-clean-branches.bash tests/git-clean-branches.bats` passed. `shellcheck -s bash -x tools/bin/git-clean-branches tests/helpers/git-clean-branches.bash tests/git-clean-branches.bats` passed. `scripts/shfmt-diff.bash` passed. `git diff --check` passed. Focused `pre-commit run --files tools/bin/git-clean-branches tests/git-clean-branches.bats tests/helpers/git-clean-branches.bash docs/tasks/20260823-195913-git-clean-branches-health-remediation.md` passed.
- Follow-ups/blockers: no blockers. No `CHANGELOG.md` edits were made.

### Task ARCH-01: Separate Planning, Rendering, And Guarded Application

Status: completed

Priority: P2

Suggested agent: Bash architecture and testability engineer

Dependencies: DISC-01, SAFE-01, STATE-01, CLI-01

Primary ownership:

- `tools/bin/git-clean-branches`
- Optional `tools/lib/picotools/git-clean-branches/*.sh`
- Direct module tests and installed-layout smoke coverage

Finding:

One `main` function currently owns every phase and mutates global debug state. Discovery and application cannot be tested directly without full repositories or command stubs, and process-substitution output acts as an implicit interface. At 183 lines this does not justify broad framework extraction, but destructive invariants need explicit boundaries.

References:

- `tools/bin/git-clean-branches:36-181`
- `lib/picotools/git.sh:14-55`
- `.opencode/skills/bash-tool-conventions/SKILL.md`

Implementation requirements:

1. Keep dependency loading, CLI dispatch, and high-level orchestration in the executable.
2. Establish narrow functions for argument parsing, protected-ref discovery, candidate planning, rendering, preflight, guarded application, and outcome reporting.
3. Pass arrays/maps by named references or another lossless explicit interface. Do not transport ref records through newline-delimited command substitution.
4. Extract a tool-specific module only if it gives pure/direct tests a clear ownership boundary; otherwise retain cohesive functions in the executable and use a guarded entry point for tests.
5. Make dependencies, outputs, and return statuses explicit. Reusable functions should return errors rather than exiting the shell.
6. Keep each safety invariant at one enforcement point: fresh default resolution, worktree protection, candidate OID validation, local compare-and-swap, and remote leases.
7. Follow repository direct-module declaration conventions even when one sourced module loads another internally.

Acceptance criteria:

- `main` reads as phase orchestration and does not contain branch-discovery parsing or ref-transaction details.
- Pure parser/planner/renderer behavior has direct tests; integration tests own real Git mutation behavior.
- Error paths return to one orchestration boundary and do not unexpectedly terminate a sourcing test shell.
- Ref names and OIDs remain lossless across every function boundary.
- Repository and installed layouts load any new module and pass help, version, and operational disposable-repository smoke tests.

Completion evidence:

- Changed files: `tools/bin/git-clean-branches`, `tests/git-clean-branches.bats`, `docs/tasks/20260823-195913-git-clean-branches-health-remediation.md`.
- Direct coverage: sourced-executable parser test for action/options/remote handling; planner test that excludes protected refs and preserves ref/OID arrays; renderer test for reviewed plans and empty-plan sentinel.
- Integration coverage: existing disposable repository mutation tests continue to own local CAS deletion, remote atomic leases, stale-plan failures, and outcome reporting; added installed-layout disposable repository smoke for dependency loading and empty-plan operation.
- Command summaries: `npm run test:git-clean-branches` passed with 43 tests. `bash -n tools/bin/git-clean-branches tests/helpers/git-clean-branches.bash tests/git-clean-branches.bats` passed. `shellcheck -s bash -x tools/bin/git-clean-branches tests/helpers/git-clean-branches.bash tests/git-clean-branches.bats` passed. `scripts/shfmt-diff.bash` passed. `git diff --check` passed. Focused `pre-commit run --files tools/bin/git-clean-branches tests/git-clean-branches.bats tests/helpers/git-clean-branches.bash docs/tasks/20260823-195913-git-clean-branches-health-remediation.md` passed.
- Follow-ups/blockers: no blockers. No module extraction was added because direct sourced-function tests provide ownership without packaging overhead. No `CHANGELOG.md` edits were made.

## Wave 4: Documentation, CI, And Measured Performance

### Task DOC-CI-01: Align Public Contracts And Repository Checks

Status: completed

Priority: P2

Suggested agent: Documentation and CI engineer

Dependencies: STATE-01, CLI-01, ARCH-01

Primary ownership:

- `README.md`
- `usage()` in `tools/bin/git-clean-branches`
- `package.json`
- `.github/workflows/test.yml`

Finding:

Public documentation understates destructive and network behavior, and the configured syntax command omits this Bats suite. Installed CI checks help/version but not an operational disposable-repository path.

References:

- `README.md:28`
- `README.md:89`
- `tools/bin/git-clean-branches:14-29`
- `package.json:15-24`
- `.github/workflows/test.yml:20-40`
- `.github/workflows/test.yml:175-176`

Implementation requirements:

1. Document that local branches are force-deleted whether merged or not, while remote candidates must be merged into the freshly resolved remote default.
2. Document fetch/prune side effects, default/current/worktree protections, confirmation behavior, compare-and-swap/lease guarantees, atomicity limits, and partial local-versus-remote failure state.
3. Document the positional remote, `--yes`, `--debug`, and `--` contracts consistently in help and README.
4. Expand `check:syntax` to cover all Bats suites safely rather than maintaining a special `git-commit` glob.
5. Keep `test:git-clean-branches` and ensure CI invokes repository-wide tests without duplicate focused execution unless duplication serves an explicit purpose.
6. Add an installed-layout operational smoke test using a disposable local repository and bare remote; it must not contact an external network.

Acceptance criteria:

- Help and README agree with runtime behavior for selection, destructive force, side effects, concurrency, and failure outcomes.
- `npm run check:syntax` parses `tests/git-clean-branches.bats` and every other applicable Bats file.
- The packed installed tool performs a harmless empty-plan or confirmed disposable cleanup using installed modules.
- `npm run test:git-clean-branches`, syntax, ShellCheck, formatting, and installed-layout CI checks pass.

Completion evidence:

- Changed files: `README.md`, `tools/bin/git-clean-branches`, `package.json`, `.github/workflows/test.yml`, `docs/tasks/20260823-195913-git-clean-branches-health-remediation.md`.
- Documentation and CI changes: README and `git-clean-branches --help` now document positional remote parsing, `--yes`, `--debug`, `--`, fetch/prune side effects, force deletion of local branches, remote merged-into-fresh-default selection, protected branches, confirmation behavior, compare-and-swap/lease guards, atomicity limits, and partial local-versus-remote failure outcomes. `check:syntax` now parses `tests/*.bats` instead of only `tests/git-commit*.bats`. CI unit tests now invoke `npm test` once, and installed-layout smoke creates a disposable local repository plus bare remote and confirms the packed installed `git-clean-branches` deletes a merged local/remote cleanup branch without external network access.
- Command summaries: `npm run test:git-clean-branches` passed with 43 tests. `npm run check:syntax` passed and includes all `tests/*.bats`. `npm run check:shellcheck` passed. `npm run check:format` passed. Packed installed-layout disposable cleanup smoke passed. Workflow YAML parsed with `python3 -c 'import yaml; ...'` after `ruby` was unavailable and configured `yq` had no project version. `git diff --check` passed. Focused `pre-commit run --files README.md tools/bin/git-clean-branches package.json .github/workflows/test.yml docs/tasks/20260823-195913-git-clean-branches-health-remediation.md` passed. CI-wide `npm test` passed with 427 tests after rerunning with a longer timeout; the first 120s attempt was terminated by the tool timeout after test 192.
- Follow-ups/blockers: no blockers or follow-ups. No `CHANGELOG.md` edits were made.

### Task PERF-01: Measure Candidate Collection And Remote Application

Status: completed

Priority: P3

Suggested agent: Bash performance engineer

Dependencies: STATE-01, ARCH-01

Primary ownership:

- Reproducible benchmark fixture under `scripts/`
- Candidate/worktree lookup implementation
- Production code only for measured improvements

Finding:

Worktree membership is an `O(local branches x worktrees)` nested scan, and current remote deletion starts one push per branch. STATE-01 should remove per-branch pushes for safety, but the remaining collection cost has not been measured.

References:

- `tools/bin/git-clean-branches:107-146`
- `tools/bin/git-clean-branches:172-180`

Implementation requirements:

1. Add a disposable benchmark for representative combinations such as 10/1,000/10,000 local refs and 1/10/100 linked worktrees; record wall time and relevant Git subprocess counts.
2. Record baseline results before changing production collection behavior.
3. Measure an associative worktree-ref set against the current nested scan.
4. Record remote application subprocess counts before and after the guarded batch push from STATE-01 without weakening leases or atomicity.
5. Retain only simple changes with a material measured benefit. Otherwise mark this task deferred with evidence and leave production code unchanged.

Acceptance criteria:

- Benchmark command, environment, fixture sizes, baseline, and after-results are recorded in this task.
- Any retained lookup optimization preserves exact default/current/worktree exclusions and unusual ref names.
- Any retained remote optimization preserves explicit per-ref leases and STATE-01 atomicity semantics.
- Focused and full tests show no behavior regression.

Completion evidence:

- Changed files: `tools/bin/git-clean-branches`, `scripts/benchmark-git-clean-branches-perf.bash`, `docs/tasks/20260823-195913-git-clean-branches-health-remediation.md`.
- Benchmark command and environment: `scripts/benchmark-git-clean-branches-perf.bash --iterations 1`; Bash `5.2.21(1)-release`; Git `2.43.0`; kernel `Linux 6.18.33.2-microsoft-standard-WSL2 x86_64 GNU/Linux`.
- Fixture sizes: synthetic disposable planner inputs for `10`, `1000`, and `10000` local refs crossed with `1`, `10`, and `100` linked-worktree branch names; fixture includes default/current exclusions plus unusual branch names `feature/slash.punct+one` and `-dash-cleanup`.
- Baseline before production collection changes: original production nested scan was measured before edits with `scripts/benchmark-git-clean-branches-perf.bash --iterations 1`; results completed through `10000/10` before the `10000/100` nested case exceeded the 300s command timeout: `10/1=20.596ms`, `10/10=21.056ms`, `10/100=24.784ms`, `1000/1=1619.635ms`, `1000/10=1353.539ms`, `1000/100=2139.918ms`, `10000/1=13804.681ms`, `10000/10=11556.681ms`. A prior `--iterations 3` baseline also timed out after `1000/100`, with the same directional result. To keep future runs practical and reproducible, the retained benchmark embeds the pre-change nested membership scan and defaults to one iteration.
- After results from the retained benchmark: `10/1` baseline `3.499ms`, production associative set `3.007ms`; `10/10` `3.411ms` to `2.902ms`; `10/100` `5.399ms` to `4.696ms`; `1000/1` `57.647ms` to `40.971ms`; `1000/10` `126.148ms` to `47.324ms`; `1000/100` `451.999ms` to `37.914ms`; `10000/1` `455.562ms` to `314.691ms`; `10000/10` `936.571ms` to `401.436ms`; `10000/100` `5825.051ms` to `386.519ms`. Candidate planning uses no Git subprocesses in either benchmarked planner path.
- Retained changes: `collect_git_clean_branches_plan` now builds an associative set for linked-worktree branch names and uses literal parameter expansion for local and remote branch-name extraction in the hot loop. This preserves full-ref/OID arrays, exact default/current/worktree exclusions, and unusual ref names while removing the measured `O(local branches x worktrees)` membership cost. No remote production change was added because STATE-01 already uses one dry-run atomic push plus one atomic deletion push with explicit per-ref leases.
- Remote application subprocess counts: for `0`, `1`, `10`, and `100` remote candidates, legacy per-branch deletion push counts are `0`, `1`, `10`, and `100`; current guarded batch push counts are `0`, `2`, `2`, and `2`, plus one `ls-remote` preflight and one `merge-base --is-ancestor` check per remote candidate. The existing `multiple remote deletions use one atomic push` test confirms exactly one dry-run push and one deletion push for multiple refs.
- Verification: `bash -n tools/bin/git-clean-branches scripts/benchmark-git-clean-branches-perf.bash tests/helpers/git-clean-branches.bash tests/git-clean-branches.bats` passed. `shellcheck -s bash -x tools/bin/git-clean-branches scripts/benchmark-git-clean-branches-perf.bash tests/helpers/git-clean-branches.bash tests/git-clean-branches.bats` passed. `npm run test:git-clean-branches` passed with 43 tests. `npm run check:syntax` passed. `npm run check:shellcheck` passed. `scripts/shfmt-diff.bash` passed. `git diff --check` passed. `npm test` passed with 427 tests. Focused `pre-commit run --files tools/bin/git-clean-branches scripts/benchmark-git-clean-branches-perf.bash docs/tasks/20260823-195913-git-clean-branches-health-remediation.md` passed.
- Residual impact: collection still performs fixed Git discovery subprocesses outside the pure planner and still revalidates each remote candidate with `merge-base --is-ancestor` to preserve safety. No `CHANGELOG.md` edits were made.

## Wave 5: Independent Integration Review

### Task REVIEW-01: Independently Verify Destructive Safety And Release Readiness

Status: completed

Priority: P1

Suggested agent: independent Git safety reviewer who did not implement prior tasks

Dependencies: TEST-01, DISC-01, SAFE-01, STATE-01, CLI-01, ARCH-01, DOC-CI-01; PERF-01 may be completed or explicitly deferred

Primary ownership:

- Review and verification only
- This task document for completion evidence or newly discovered follow-up tasks

Finding:

Destructive ref cleanup needs an independent review across alternate race, worktree, remote, argument, and installed-layout paths after implementation tasks converge.

References:

- All findings and acceptance criteria in this document

Implementation requirements:

1. Verify every acceptance criterion against runtime behavior, not only test names or implementation structure.
2. Attempt local and remote ref movement during confirmation, default-branch movement, new linked-worktree checkout, candidate disappearance, and injected discovery/application failures. Characterize races Git cannot atomically guard instead of overstating client-side guarantees.
3. Inspect exact Git argv for option separation, full refs, expected old OIDs, explicit leases, batching, and atomic behavior.
4. Confirm parser, help, README, implementation, tests, package scripts, and installed artifact agree.
5. Run the full verification ladder and record exact counts/results. Do not mark completion around failures.
6. Add concrete follow-up tasks for newly confirmed defects; distinguish residual risks and unsupported remote capabilities from defects.

Acceptance criteria:

- No candidate whose OID changed after confirmation is deleted; protection state is revalidated at the latest supported boundary and any unavoidable remote-default or worktree-attachment race is explicitly documented.
- Discovery uncertainty and stale default metadata fail before mutation.
- Local and remote partial-failure behavior matches the documented contract and accounts for every candidate.
- Direct, focused, repository-wide, static, pre-commit, and installed-artifact checks pass.
- Deferred performance work includes evidence and residual impact.

Completion evidence:

- Changed files for REVIEW-01: `tools/bin/git-clean-branches`, `tests/git-clean-branches.bats`, `tests/helpers/git-clean-branches.bash`, `README.md`, `docs/tasks/20260823-195913-git-clean-branches-health-remediation.md`. `CHANGELOG.md` was not edited. Pre-existing unrelated/concurrent changes were preserved, including `.github/workflows/test.yml`, `package.json`, `tools/bin/git-clean-task-pr`, `scripts/benchmark-git-clean-branches-perf.bash`, and `docs/tasks/20260823-200127-model-profile-health-remediation.md`.
- Review coverage: re-read this complete task file, `tools/bin/git-clean-branches`, focused Bats tests/helpers, `README.md`, `package.json`, `.github/workflows/test.yml`, and the retained performance benchmark. Verified acceptance criteria against runtime behavior for local candidate OID movement, remote candidate movement from a second clone, default branch target movement, remote default branch OID movement, late linked-worktree checkout, local/remote candidate disappearance, injected discovery failures, injected local transaction failure, injected between-phase failure, injected remote push failure, unsupported atomic remote behavior, parser/help/version behavior, installed layout loading, and disposable installed cleanup.
- Finding and narrow fix: manual reproduction showed that rewinding `origin/main` on the remote after the reviewed plan but before confirmation still allowed deletion of a remote branch that was no longer merged into the remote default. The tool now records the reviewed remote default OID and preflights the current remote default OID with `git ls-remote --heads -- <remote> <default>` before any mutation; a mismatch rejects the stale plan. Added `rejects stale plan when the remote default branch OID moves before deletion` and updated help/README to document the guard and remaining race.
- Git argv inspection: option boundaries use `--` for remote operands in `git remote get-url -- <remote>`, `git fetch --prune -- <remote>`, `git ls-remote --symref -- <remote> HEAD`, `git ls-remote --exit-code --heads -- <remote> main`, `git ls-remote --heads -- <remote> [branch]`, and `git merge-base --is-ancestor -- <oid> <default-ref>`. Discovery uses full refs with `git for-each-ref --format='%(refname) %(objectname)' refs/heads` and `--merged refs/remotes/<remote>/<default> refs/remotes/<remote>`. Local deletion batches `start`, full-ref `delete <ref> <reviewed-oid>`, `prepare`, and `commit` through one `git update-ref --stdin` transaction. Remote atomic preflight and deletion build array argv with full destination refs, explicit `--force-with-lease=refs/heads/<branch>:<reviewed-oid>` per candidate, `--atomic`, `--porcelain`, one `-- <remote>` separator, and full delete refspecs `:refs/heads/<branch>`.
- Command results: initial focused `npm run test:git-clean-branches` after the remote-default-OID fix failed because `remote_head_oid` shadowed the output variable used by `collect_command_output`; after correcting that, `npm run test:git-clean-branches` passed with 44 tests. `npm test` passed with 428 tests. `npm run check:syntax` passed. `npm run check:shellcheck` passed. `npm run check:format` passed. `pre-commit run --all-files` passed. Packed installed-layout smoke equivalent to `.github/workflows/test.yml` passed from `/tmp/opencode/picotools-install-smoke.MF6miy`, including the installed `git-clean-branches --help`, `--version`, and disposable confirmed cleanup path that removed both local and bare-remote `cleanup` refs.
- Acceptance status: local/remote candidate OID movement is rejected before deletion; candidate disappearance is stale and cannot delete a replacement ref; default target and default OID movement are rejected before local mutation; current/default/worktree protections are revalidated immediately before mutation; discovery uncertainty fails before rendering an actionable deletion plan; local/remote partial-failure summaries account for succeeded, stale/skipped, failed, and not-attempted operations; help, README, parser, package scripts, implementation, tests, workflow smoke, and installed artifact agree.
- Residual risks: `git update-ref --stdin` provides expected-OID compare-and-swap but does not enforce linked-worktree occupancy, so a branch checked out after the final worktree preflight and before the local transaction remains an unavoidable Git-client race. Remote candidate refs are protected by explicit leases in the final atomic push, but the remote default branch cannot be leased as part of a delete push for unrelated candidate refs; remote default movement after the final default-OID preflight and before the atomic push remains a documented server-side race. Non-atomic remotes intentionally fail closed before mutation.
- Performance evidence: PERF-01 is completed with benchmark command/environment, fixture sizes, baseline/after timings, retained associative worktree lookup evidence, remote subprocess counts, and residual impact recorded above; no additional performance work was required for REVIEW-01.
- Follow-ups/blockers: no open blockers after the narrow fix. No new follow-up task was added because the only newly confirmed defect was fixed and covered here.

## Dependency And Parallelization Guidance

| Wave | Task | May run in parallel with | Shared hotspots |
| --- | --- | --- | --- |
| 1 | TEST-01 | None initially | `tests/git-clean-branches.bats`, `package.json` |
| 2 | DISC-01 | CLI-01 after TEST-01 | `tools/bin/git-clean-branches` |
| 2 | SAFE-01 | None; sequence after DISC-01 | Candidate/apply model |
| 2 | STATE-01 | None; sequence after SAFE-01 | Destructive apply path |
| 3 | CLI-01 | DISC-01 after TEST-01 if agents coordinate executable edits | Parser and usage |
| 3 | ARCH-01 | None; integrate stabilized prior behavior | Executable and new module boundaries |
| 4 | DOC-CI-01 | PERF-01 after architecture stabilizes | README, package/CI, usage |
| 4 | PERF-01 | DOC-CI-01 | Benchmark and candidate lookup |
| 5 | REVIEW-01 | None | Read-only review plus task evidence |

- `tools/bin/git-clean-branches` is the primary shared hotspot. Prefer sequential ownership through DISC-01, SAFE-01, STATE-01, CLI-01, and ARCH-01 unless agents coordinate non-overlapping patches.
- TEST-01 should establish helpers and focused files before other agents add regressions. Later agents should own concern-specific test files rather than rebuilding one monolith.
- Do not run formatting or repository-wide tests concurrently with another agent writing shared files.
- A change to `lib/picotools/git.sh` must be coordinated with `git-clean-task-pr` tests and consumers; prefer a tool-specific strict resolver if shared compatibility is uncertain.

## Deferred Decisions

### Atomic Remote Compatibility

Recommended default: require atomic remote deletion and fail closed before remote mutation when the server does not advertise/support it. This avoids a misleading all-or-nothing plan becoming a partial remote cleanup. If maintainers require compatibility with non-atomic servers, STATE-01 must add an explicit opt-in mode, document that partial deletion is possible, preserve per-ref leases, and report each applied/failed/not-attempted ref. Do not silently fall back.

### Shared Default-Branch Helper

Recommended default: keep destructive authoritative resolution inside `git-clean-branches` unless `picotools_git_default_branch` can gain an explicit strict mode without changing `git-clean-task-pr` fallback behavior. Do not globally remove fallback behavior without consumer review and tests.

### Minimum Git Version

Before choosing `git update-ref --stdin` transaction options or atomic push behavior, record the repository's supported minimum Git version. If no support policy exists, use the Git version available in the oldest supported CI/runtime environment and document required capabilities rather than adding an untested compatibility shim.

## Definition Of Done

- Every confirmed P0/P1 finding has a failing-before/passing-after regression and completion evidence.
- Candidate plans bind full refs to reviewed object IDs; current/default/worktree protections and merge eligibility are fresh at application time.
- Local deletion uses compare-and-swap transaction semantics and remote deletion uses explicit per-ref leases with the documented atomicity contract.
- Discovery and metadata failures cannot produce a deletion prompt, `Nothing to delete`, or destructive action.
- Every partial or failed operation produces an accurate bounded outcome summary and recovery guidance.
- Parsing rejects unknown options and supports the documented option terminator.
- Planning, rendering, preflight, and application have explicit lossless interfaces and direct tests without unnecessary framework extraction.
- README, help, package scripts, CI, and installed artifacts agree with runtime behavior.
- Measured performance work is either retained with evidence or deferred without speculative production complexity.
- `npm test`, `npm run check:syntax`, `npm run check:shellcheck`, `npm run check:format`, `pre-commit run --all-files`, and installed-layout smoke tests pass.
- REVIEW-01 is completed by an independent reviewer, and all deferred decisions record rationale and residual risk.
