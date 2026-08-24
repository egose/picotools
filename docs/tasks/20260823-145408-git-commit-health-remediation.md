# Git Commit Health Remediation

Created: 2026-08-23 14:54:08 -0700

## Objective

Make `git-commit` fail closed before destructive Git operations, preserve the exact file partition approved by the generated plan, define safe hook and pull-request behavior, and then improve readability, encapsulation, reuse, testability, and measured performance.

## Scope

- `tools/bin/git-commit`
- `lib/picotools/git_commit_model.sh`
- `lib/picotools/git_commit_plan.sh`
- `lib/picotools/git_commit_workspace.sh`
- New cohesive `git_commit_*.sh` modules when extraction is justified by the tasks below
- `tests/git-commit.bats`, `tests/git-commit-modules.bats`, and new focused Git commit test/helper files
- `README.md`, `package.json`, and CI workflows for changed public and verification contracts

## Working Rules And Non-Goals

- Inspect `git status --short` before each task. Preserve unrelated concurrent changes and never revert another agent's work.
- Serialize agents that modify `tools/bin/git-commit` or the current monolithic `tests/git-commit.bats` until stable modules and test files have been extracted.
- Add a failing regression before each confirmed behavior fix. Do not weaken exact-once changed-file coverage to accommodate model output.
- Treat filenames, model responses, repository hooks, Git configuration, and API responses as untrusted input.
- Keep PAT bytes out of argv, debug output, errors, task evidence, and committed fixtures. Preserve the repository-PAT precedence established in `docs/tasks/20260818-212431-repository-git-profile-pat-auth.md`.
- Do not automatically reset commits, indexes, worktrees, or remote branches after a failure. Define and test recovery behavior before adding rollback.
- Do not build a generic framework for all picotools. Extract only stable `git-commit` domains, and move behavior to a shared module only when another tool uses the same contract.
- Do not retain performance changes without a reproducible material improvement.

## Confirmed Baseline

- The executable is 1,968 lines and still owns option parsing, configuration, scope inference, hook execution, prompt construction, rendering, commit execution, push/remote resolution, GitHub parsing, authentication, PR lifecycle, and orchestration (`tools/bin/git-commit:1-1968`).
- Three modules exist, but they depend on undeclared executable globals or callbacks: `ALLOWED_TYPES`; prompt-size constants; `debug_log`; temp-file registration; and `run_model_profile` (`lib/picotools/git_commit_plan.sh:8-18`, `lib/picotools/git_commit_workspace.sh:161-267`, `lib/picotools/git_commit_model.sh:37-119`).
- The focused integration suite is 2,959 lines. Its first 643 lines contain assertions, stubs, and fixtures, including a partial Python reimplementation of `jq` (`tests/git-commit.bats:1-643`).
- The focused suites contain 73 passing tests, but do not cover parser-status propagation, literal Git pathspecs, stale plans/indexes, scoped hooks, hook working directory, PR-list failures, fetch/push URL divergence, or unusual Git filenames.
- Worktree at review time was clean (`git status --short` produced no output).

## Baseline Verification

Run on 2026-08-23 before creating this task:

- `bats tests/git-commit-modules.bats tests/git-commit.bats`: 73 passed.
- `bash -n tools/bin/git-commit lib/picotools/git_commit_model.sh lib/picotools/git_commit_plan.sh lib/picotools/git_commit_workspace.sh tests/git-commit.bats tests/git-commit-modules.bats`: passed.
- `shellcheck -s bash -x tools/bin/git-commit lib/picotools/git_commit_model.sh lib/picotools/git_commit_plan.sh lib/picotools/git_commit_workspace.sh tests/git-commit.bats tests/git-commit-modules.bats`: passed.
- `shfmt --diff --indent 2 tools/bin/git-commit lib/picotools/git_commit_model.sh lib/picotools/git_commit_plan.sh lib/picotools/git_commit_workspace.sh tests/git-commit.bats tests/git-commit-modules.bats`: passed with no diff.
- `git diff --check`: passed.
- Full `bats tests/*.bats`, `pre-commit run --all-files`, and installed-archive tests were not run because this review only creates a task document.

## Priorities

- P0: A confirmed path that can commit files outside explicit scope/plan or continue after invalid input.
- P1: Confirmed security, correctness, state-integrity, or remote-side-effect defects.
- P2: Architecture, testability, CI, documentation, and compatibility hardening.
- P3: Optional performance work that requires measurement before production changes.

## Required Verification Ladder

Every implementation task must record the changed files, failing-before/passing-after regression, command output summary, and follow-up findings in a `Completion evidence` block. A task is not complete until its focused tests and the applicable checks below pass or an exact blocker is recorded.

1. Focused test: run the task-owned Bats file(s), using `npm run test:git-commit` after TEST-01 adds that script.
2. Package test: `bats tests/git-commit*.bats` using the final filenames.
3. Syntax: `bash -n tools/bin/git-commit lib/picotools/git_commit_*.sh tests/git-commit*.bats`, expanded for any new helper/module paths.
4. Static checks: `shellcheck -s bash -x` on every changed shell/Bats file, `scripts/shfmt-diff.bash`, and `git diff --check`.
5. Focused pre-commit: `pre-commit run --files <all files changed by the task>`.
6. Final integration only: `bats tests/*.bats`, `pre-commit run --all-files`, and the installed-archive smoke path from `.github/workflows/test.yml`.

## Wave 1: Fail-Closed Input And File Boundaries

### Task SAFE-01: Make Option Parsing And Path-File Loading Fail Closed

Status: completed

Priority: P0

Suggested agent: Bash CLI boundary engineer

Dependencies: none

Primary ownership:

- `tools/bin/git-commit`
- `lib/picotools/git_commit_workspace.sh`
- Focused option tests, preferably a new `tests/git-commit-options.bats`

Finding:

`load_scope_paths_file` exits inside process substitution used by `mapfile`, and `parse_run_options` is itself called through process substitution. `mapfile` does not propagate the producer's failure. A missing `--path-file`, unknown trailing option, or missing option value can therefore print an error while the parent continues with empty/default parser state. In the destructive case, `--apply --path-file missing` can become an unscoped apply over all workspace changes.

References:

- `tools/bin/git-commit:1550-1689`
- `tools/bin/git-commit:1861-1880`
- `lib/picotools/git_commit_workspace.sh:87-101`
- Existing positive path tests: `tests/git-commit.bats:898-1006`

Implementation requirements:

1. Run parsing in the current shell and populate caller-owned scalar/associative state and a path array through explicit interfaces; do not serialize parser state through stdout.
2. Make path-file loading return nonzero directly to its caller and populate a caller-owned array without process substitution.
3. Reserve `exit` for command dispatch; reusable parser/module functions should return errors that the orchestrator handles once.
4. Abort before hooks, model/API calls, staging, commits, or pushes for every parse/path-file error.
5. Preserve repeatable mixed `--path` and `--path-file` ordering and the existing implied `--pr -> --push -> --apply` behavior.

Acceptance criteria:

- Both forms of a missing path file return nonzero: `--path-file missing` and `--path-file=missing`.
- `--apply --path-file missing` creates no commit and never falls back to unscoped changes.
- Unknown options after valid options and missing values for `--scope`, `--path`, and `--pre-commit-retries` return nonzero.
- Hook, model, Git API, `git add`, and `git commit` stubs are not invoked after parser failure.
- Valid mixed/repeated path options preserve all entries exactly.
- `bats tests/git-commit-options.bats tests/git-commit.bats` passes using the final filenames.

Completion evidence:

- Changed files: `tools/bin/git-commit`, `lib/picotools/git_commit_workspace.sh`, `tests/git-commit-options.bats`, `docs/tasks/20260823-145408-git-commit-health-remediation.md`.
- Regression/focused tests: added `tests/git-commit-options.bats` covering both missing `--path-file` syntaxes, `--apply --path-file missing` no-commit/no-staging behavior, unknown trailing option fail-closed behavior, missing `--scope`/`--path`/`--pre-commit-retries` values, no hook/model/Git API/`git add`/`git commit` stubs after parser failure, direct parser order/repetition preservation, and valid mixed repeated `--path`/`--path-file` entries with exact paths including spaces.
- Command summaries: `bats tests/git-commit-options.bats tests/git-commit.bats` passed, 74 tests; `bash -n tools/bin/git-commit lib/picotools/git_commit_workspace.sh tests/git-commit-options.bats` passed; `shellcheck -s bash -x tools/bin/git-commit lib/picotools/git_commit_workspace.sh tests/git-commit-options.bats` passed; `scripts/shfmt-diff.bash` passed with no diff; `git diff --check` passed; `pre-commit run --files docs/tasks/20260823-145408-git-commit-health-remediation.md tools/bin/git-commit lib/picotools/git_commit_workspace.sh tests/git-commit-options.bats` passed.
- Follow-ups: none for SAFE-01. Literal pathspec safety, lossless filename handling, and broader hook/index behavior remain owned by later tasks.

### Task SAFE-02: Use Literal Git Pathspecs At Every Filename Boundary

Status: completed

Priority: P0

Suggested agent: Git pathspec security engineer

Dependencies: SAFE-01

Primary ownership:

- `lib/picotools/git_commit_workspace.sh`
- Commit staging/rendering functions currently in `tools/bin/git-commit`
- Focused literal-path tests

Finding:

Repository filenames are passed to Git as `:/$file`. Root anchoring does not disable pathspec syntax, so `*`, `?`, `[`, and pathspec magic can match additional paths. A planned file named `release*.txt` can stage `release1.txt`, violating exact-once plan validation and potentially committing a file that was not present during planning.

References:

- `lib/picotools/git_commit_workspace.sh:161-210`
- `tools/bin/git-commit:1717-1729`
- `tools/bin/git-commit:1818-1857`

Implementation requirements:

1. Centralize conversion from repository-relative filenames to top-anchored literal Git pathspecs, such as `:(top,literal)<path>`.
2. Apply the literal boundary to diff collection, tracked-file checks, temporary-index staging, preview rendering, and real-index staging.
3. Keep `--` operand separation even when literal pathspec magic is used.
4. Ensure preview commands accurately represent the argv executed by apply mode rather than duplicating a different quoting/pathspec policy.
5. Preserve deletion, rename, and repository-root invocation behavior.

Acceptance criteria:

- Separate planned files named `a*.txt` and `abc.txt` are committed only in their assigned commits.
- Equivalent regressions cover `?`, bracket expressions, a leading `:`, spaces, and shell metacharacters.
- A file created after planning that merely matches another filename's metacharacters is not staged.
- Preview and apply use the same literal pathspec semantics.
- Focused path tests and the complete Git commit suite pass.

Completion evidence:

- Changed files: `lib/picotools/git_commit_workspace.sh`, `tools/bin/git-commit`, `tests/git-commit-paths.bats`, `tests/git-commit.bats`, `tests/git-commit-options.bats`, `docs/tasks/20260823-145408-git-commit-health-remediation.md`.
- Regression/focused tests: added `tests/git-commit-paths.bats` covering separated `a*.txt` and `abc.txt` commits, post-planning matcher files left unstaged, literal handling for `?`, bracket expressions, leading `:`, spaces, and shell metacharacters, and preview `git add` rendering matching apply argv semantics.
- Command summaries: `bats tests/git-commit-paths.bats` passed, 3 tests; `bats tests/git-commit*.bats` passed, 82 tests; `bash -n tools/bin/git-commit lib/picotools/git_commit_workspace.sh tests/git-commit-paths.bats tests/git-commit-options.bats tests/git-commit.bats tests/git-commit-modules.bats` passed; `shellcheck -s bash -x tools/bin/git-commit lib/picotools/git_commit_workspace.sh tests/git-commit-paths.bats tests/git-commit-options.bats tests/git-commit.bats tests/git-commit-modules.bats` passed; `scripts/shfmt-diff.bash` passed with no diff; `git diff --check` passed; `pre-commit run --files docs/tasks/20260823-145408-git-commit-health-remediation.md tools/bin/git-commit lib/picotools/git_commit_workspace.sh tests/git-commit-paths.bats tests/git-commit-options.bats tests/git-commit.bats tests/git-commit-modules.bats` passed.
- Follow-ups: none for SAFE-02. Lossless newline/tab/non-ASCII filename representation and broader hook/index isolation remain owned by later tasks.

### Task PATH-01: Represent Git Filenames Losslessly

Status: completed

Priority: P2

Suggested agent: Bash data-model and Git plumbing engineer

Dependencies: SAFE-01, SAFE-02

Primary ownership:

- `lib/picotools/git_commit_workspace.sh`
- `lib/picotools/git_commit_plan.sh`
- New focused workspace/plan tests
- Orchestration call sites in `tools/bin/git-commit`

Finding:

Changed filenames are transported as newline-delimited scalar strings. Git output is not requested with `-z`, and `jq` file arrays are also converted through newline-delimited output. Valid filenames containing newlines cannot be represented; tabs, backslashes, quotes, and non-ASCII paths can be C-quoted by Git and cease to identify the actual file.

References:

- `lib/picotools/git_commit_workspace.sh:58-152`
- `lib/picotools/git_commit_workspace.sh:213-244`
- `lib/picotools/git_commit_plan.sh:115-224`
- `tools/bin/git-commit:584-615`

Implementation requirements:

1. Collect Git filenames with NUL-delimited commands and keep them in Bash arrays or another lossless internal representation.
2. Define an unambiguous JSON prompt representation and require the model to return exact repository-relative strings.
3. Remove fuzzy basename/suffix resolution unless a concrete external compatibility requirement is documented; exact paths are the safer contract already requested in the prompt.
4. Build lookup maps once for validation rather than rescanning a serialized changed-file string.
5. Keep scope filtering, deleted files, renames, and untracked files lossless.

Acceptance criteria:

- Preview and apply address exact filenames containing newline, tab, backslash, quote, leading colon, spaces, glob characters, and non-ASCII characters.
- Ambiguous basenames are rejected, and exact full paths always resolve deterministically.
- Changed-file exact-once validation remains enforced.
- Deleted and renamed files are covered in prompt and apply tests.
- Direct workspace/plan module tests and end-to-end tests pass.

Completion evidence:

- Changed files: `lib/picotools/git_commit_workspace.sh`, `lib/picotools/git_commit_plan.sh`, `tools/bin/git-commit`, `tests/git-commit-modules.bats`, `tests/git-commit-paths.bats`, `tests/git-commit-options.bats`, `tests/git-commit.bats`, `docs/tasks/20260823-145408-git-commit-health-remediation.md`.
- Regression/focused tests: added direct plan/workspace coverage for exact path validation, duplicate basename rejection with exact full-path acceptance, newline path validation, and JSON prompt escaping for newline/tab/backslash filenames; added end-to-end path coverage for apply/preview with newline, tab, backslash, quote, leading colon, spaces, glob characters, and non-ASCII filenames; added deleted and renamed prompt/apply coverage; updated legacy basename-apply expectations to exact repo-relative paths.
- Command summaries: `bats tests/git-commit-modules.bats tests/git-commit-paths.bats` passed, 14 tests; `bats tests/git-commit*.bats` passed, 88 tests; `bash -n tools/bin/git-commit lib/picotools/git_commit_workspace.sh lib/picotools/git_commit_plan.sh tests/git-commit-modules.bats tests/git-commit-paths.bats tests/git-commit-options.bats tests/git-commit.bats` passed; `shellcheck -s bash -x tools/bin/git-commit lib/picotools/git_commit_workspace.sh lib/picotools/git_commit_plan.sh tests/git-commit-modules.bats tests/git-commit-paths.bats tests/git-commit-options.bats tests/git-commit.bats` passed; `scripts/shfmt-diff.bash` passed with no diff; `git diff --check` passed; `pre-commit run --files docs/tasks/20260823-145408-git-commit-health-remediation.md lib/picotools/git_commit_plan.sh lib/picotools/git_commit_workspace.sh tests/git-commit-modules.bats tests/git-commit.bats tests/git-commit-options.bats tests/git-commit-paths.bats tools/bin/git-commit` passed.
- Follow-ups: none for PATH-01. Broader state-integrity and hook/index isolation remain owned by later tasks.

## Wave 2: State Integrity And Hook Safety

### Task STATE-01: Reject Stale Plans And Isolate Each Commit Index

Status: completed

Priority: P0

Suggested agent: Git index and transaction engineer

Dependencies: SAFE-01, SAFE-02; PATH-01 preferred before final implementation

Primary ownership:

- Commit preparation/execution functions in `tools/bin/git-commit`
- New execution module if introduced
- Focused apply/state tests

Finding:

The tool snapshots names and diffs before model/API calls, then stages current path contents later without revalidating the real index, file set, or content. `git commit` commits the complete real index. Another process or hook can stage an unrelated file, and a selected file can change after the model saw it. Normal commit hooks can also stage a file assigned to a later planned commit, invalidating the approved partition.

References:

- `tools/bin/git-commit:1426-1479`
- `tools/bin/git-commit:1818-1859`
- `tools/bin/git-commit:1917-1937`

Implementation requirements:

1. Capture a workspace fingerprint sufficient to detect selected path-set and content changes after hook checks and model/API calls.
2. Immediately before apply, require the real index to match the accepted empty-index precondition and require the selected workspace fingerprint to match the planned snapshot.
3. Before each commit, construct or verify an index containing exactly the intended files; do not rely on `git commit` ignoring unrelated staged entries.
4. Detect files added by real commit hooks to the wrong planned commit. Either isolate them or fail with precise recovery state; never silently violate the plan.
5. Define first-commit, later-commit, push, and PR failure state. Do not auto-reset published commits or remote branches.
6. Print actionable recovery information after partial local application.

Acceptance criteria:

- A model stub that stages `unrelated-secret.txt` causes apply to fail before any commit; the unrelated path is never committed.
- A selected file mutated during model execution causes a stale-plan error before commit.
- A new, deleted, or renamed selected path after planning is detected.
- A real hook that stages a later commit's file cannot move it into the current commit undetected.
- Injected failure in commit 1 and commit 2 leaves the documented HEAD/index/worktree state and prints accurate recovery guidance.
- Push and PR failures preserve local/remote state according to the documented contract.

Completion evidence:

- Changed files: `tools/bin/git-commit`, `tests/git-commit-state.bats`, `tests/git-commit-paths.bats`, `tests/git-commit-options.bats`, `tests/git-commit.bats`, `docs/tasks/20260823-145408-git-commit-health-remediation.md`.
- Regression/focused tests: added `tests/git-commit-state.bats` covering model-side staging of `unrelated-secret.txt` rejected before commit, selected content mutation during model execution, new/deleted/renamed selected paths after planning, hook staging of a later commit file, injected commit 1 and commit 2 failures with HEAD/index/worktree recovery guidance, rejected push preservation, and PR failure preservation after push.
- Command summaries: `bats tests/git-commit-state.bats` passed, 8 tests; `bats tests/git-commit*.bats` passed, 96 tests; `bash -n tools/bin/git-commit tests/git-commit-state.bats tests/git-commit-paths.bats tests/git-commit-options.bats tests/git-commit.bats` passed; `shellcheck -s bash -x tools/bin/git-commit tests/git-commit-state.bats tests/git-commit-paths.bats tests/git-commit-options.bats tests/git-commit.bats` passed; `scripts/shfmt-diff.bash` passed with no diff; `git diff --check` passed; `pre-commit run --files docs/tasks/20260823-145408-git-commit-health-remediation.md tools/bin/git-commit tests/git-commit-state.bats tests/git-commit-paths.bats tests/git-commit-options.bats tests/git-commit.bats` passed.
- Follow-ups: none for STATE-01. Existing broader hook execution semantics remain owned by HOOK-01; PR lookup/topology hardening remains owned by PR-01.

### Task HOOK-01: Make Preliminary Hook Execution Explicit And Scope-Accurate

Status: completed

Priority: P1

Suggested agent: Git hooks and temporary-index engineer

Dependencies: SAFE-01, SAFE-02

Primary ownership:

- Hook functions currently in `tools/bin/git-commit:618-670`
- New `lib/picotools/git_commit_hooks.sh` if extracted
- Focused hook tests
- Help/README hook contract

Finding:

The preliminary hook receives a filtered changed-file string but ignores it and stages the entire workspace into a temporary index. The debug count is therefore always zero. It also runs in preview mode and invokes the repository-controlled executable directly from the caller's current directory, unlike Git's repository-root hook working directory. Copying the real index fails in an unborn repository where `.git/index` does not yet exist.

References:

- `tools/bin/git-commit:618-670`
- `tools/bin/git-commit:1426-1474`
- `tools/bin/git-commit:1886-1888`
- Existing hook tests: `tests/git-commit.bats:1530-1728`
- Public scope promise: `README.md:51`

Implementation requirements:

1. Resolve the maintainer decision under Deferred Decisions before changing preview behavior. The recommended contract is no repository-code execution in preview unless explicitly requested.
2. For any preliminary run, build the temporary index from exactly the selected literal paths, including deletions, and report the real count.
3. Invoke the hook with the repository root as working directory and preserve the Git hook environment needed by supported hooks.
4. Initialize a valid empty temporary index when no real index exists; include a split-index compatibility test.
5. Detect and reject out-of-scope worktree mutations by preliminary hooks rather than staging or committing them silently.
6. Document that hooks are repository-controlled code and distinguish preliminary checks from hooks invoked by `git commit`.

Acceptance criteria:

- A scoped run's hook sees only selected paths in its temporary index.
- Unrelated modified/untracked files do not fail an index-sensitive scoped hook and are not changed, staged, or committed.
- A hook invoked from a nested working directory observes the repository root as `$PWD`.
- An unborn repository with an executable successful hook can create its initial commit.
- Split-index behavior is tested; unsupported behavior fails before mutation with a clear diagnostic.
- Preview hook behavior matches the documented maintainer decision and has a side-effect regression test.

Completion evidence:

- Changed files: `tools/bin/git-commit`, `tests/git-commit-hooks.bats`, `tests/git-commit.bats`, `README.md`, `docs/tasks/20260823-145408-git-commit-health-remediation.md`.
- Regression/focused tests: added `tests/git-commit-hooks.bats` covering selected-path-only temporary indexes with deletions, unrelated tracked/untracked paths left unstaged and uncommitted, repository-root hook working directory from a nested invocation, unborn initial commit support, split-index fail-closed behavior before hook mutation, preview-mode hook skip with no side effect, and rejection of out-of-scope preliminary hook worktree mutations; updated legacy pre-commit tests to run preliminary hooks only in apply mode and keep hook-mutated support files inside the selected changed set.
- Command summaries: `bats tests/git-commit-hooks.bats` passed, 5 tests; `bats tests/git-commit*.bats` passed, 101 tests; `bash -n tools/bin/git-commit lib/picotools/git_commit_model.sh lib/picotools/git_commit_plan.sh lib/picotools/git_commit_workspace.sh tests/git-commit.bats tests/git-commit-modules.bats tests/git-commit-hooks.bats tests/git-commit-options.bats tests/git-commit-paths.bats tests/git-commit-state.bats` passed; `shellcheck -s bash -x tools/bin/git-commit lib/picotools/git_commit_workspace.sh tests/git-commit.bats tests/git-commit-hooks.bats` passed; `scripts/shfmt-diff.bash` passed with no diff; `git diff --check` passed; `pre-commit run --files docs/tasks/20260823-145408-git-commit-health-remediation.md README.md tools/bin/git-commit tests/git-commit.bats tests/git-commit-hooks.bats` passed.
- Follow-ups: none for HOOK-01. Later PR/model/documentation/CI hardening remains owned by pending tasks.

## Wave 3: Model, API, And Diagnostic Boundaries

### Task PLAN-01: Validate The Complete Model Plan Before Accepting It

Status: completed

Priority: P1

Suggested agent: JSON contract and model-boundary engineer

Dependencies: SAFE-01; PATH-01 if it changes the file representation

Primary ownership:

- `lib/picotools/git_commit_plan.sh`
- Planning/retry orchestration in `tools/bin/git-commit`
- `tests/git-commit-modules.bats` or a new plan suite

Finding:

The authoritative validation checks only commit count and file coverage. Type and message checks occur later in `read_commit_plan_item`, after the response was logged as validated, so invalid types/messages bypass the corrective retry. Schema checks do not prove that each commit is an object with string `type`/`message` and a nonempty string array, or that PR metadata has the expected object shape.

References:

- `lib/picotools/git_commit_plan.sh:54-73`
- `lib/picotools/git_commit_plan.sh:159-239`
- `tools/bin/git-commit:819-860`
- `tools/bin/git-commit:1299-1385`
- Existing invalid-message test: `tests/git-commit.bats:845-869`

Implementation requirements:

1. Define one complete plan schema and semantic validation boundary before rendering or execution.
2. Validate object/array/string types, nonempty fields and file arrays, allowed commit types, message style, full header feasibility, exact file coverage, and PR metadata when requested.
3. Return validation errors from module functions instead of exiting deep in reusable helpers.
4. Feed every correctable validation error into the existing bounded retry flow.
5. Parse or normalize plan data once where practical so rendering and execution consume validated data rather than repeatedly interpreting raw JSON.

Acceptance criteria:

- Table-driven module tests reject null, boolean, number, object, missing, and empty values at every schema position.
- Invalid type and invalid message trigger the bounded correction retry.
- Renderer and executor do not discover a new schema/semantic error after validation succeeds.
- PR and non-PR schema behavior is covered separately.
- Exact-once path coverage remains enforced for one and multiple commits.

Completion evidence:

- Changed files: `lib/picotools/git_commit_plan.sh`, `tools/bin/git-commit`, `tests/git-commit-modules.bats`, `tests/git-commit.bats`, `tests/git-commit-options.bats`, `docs/tasks/20260823-145408-git-commit-health-remediation.md`.
- Regression/focused tests: added table-driven plan module coverage for invalid root, commits, commit item, type, message, files, file element, PR object, PR title, and PR body schema values; added semantic validation coverage for invalid commit type, invalid message style, header feasibility, PR/non-PR metadata behavior, and exact-once path coverage for single and multiple commits; added CLI regressions proving invalid type and invalid message enter the bounded correction retry; updated preview/header and PR assertions for the new pre-render validation boundary.
- Command summaries: `bats tests/git-commit-modules.bats` passed, 13 tests; `bats tests/git-commit.bats` passed, 70 tests; `bats tests/git-commit-options.bats` passed, 6 tests; `bats tests/git-commit*.bats` passed, 107 tests; `bash -n tools/bin/git-commit lib/picotools/git_commit_plan.sh tests/git-commit-modules.bats tests/git-commit.bats tests/git-commit-options.bats` passed; `shellcheck -s bash -x tools/bin/git-commit lib/picotools/git_commit_plan.sh tests/git-commit-modules.bats tests/git-commit.bats tests/git-commit-options.bats` passed; `scripts/shfmt-diff.bash` passed with no diff after one indentation fix; `git diff --check` passed; `pre-commit run --files docs/tasks/20260823-145408-git-commit-health-remediation.md lib/picotools/git_commit_plan.sh tools/bin/git-commit tests/git-commit-modules.bats tests/git-commit.bats tests/git-commit-options.bats` passed.
- Follow-ups: none for PLAN-01. Raw model diagnostic redaction remains owned by DIAG-01; PR lookup/topology hardening remains owned by PR-01.

### Task DIAG-01: Bound And Redact Model Diagnostics

Status: completed

Priority: P1

Suggested agent: CLI secrets and diagnostics engineer

Dependencies: PLAN-01

Primary ownership:

- `lib/picotools/git_commit_model.sh`
- Model failure/retry orchestration
- Focused diagnostics tests

Finding:

After final validation failure, the complete raw model response is printed to stderr even without `--debug`. The response can echo source diffs, PR bodies, credentials, or terminal control sequences. Provider stdout is also captured without a response-size bound.

References:

- `lib/picotools/git_commit_model.sh:37-47`
- `lib/picotools/git_commit_model.sh:49-119`
- `tools/bin/git-commit:1341-1384`

Implementation requirements:

1. Do not print raw model output in normal mode; report a bounded validation diagnostic.
2. Define explicit debug/diagnostic behavior with output length limits, terminal-control escaping, and credential redaction.
3. Bound accepted provider response bytes before storing or parsing the complete result; fail with a stable diagnostic on overflow.
4. Ensure temporary prompt/response files retain restrictive permissions and are removed on success, failure, and handled signals.
5. Never place prompt content or credentials in process arguments.

Acceptance criteria:

- Malformed model output containing a sentinel secret and ANSI/control bytes does not expose either in normal stderr.
- Debug output follows the documented redaction and truncation contract.
- An oversized response fails within a tested memory/output bound.
- Prompt and diagnostic temporary files are absent after success and failure.
- Existing primary/additional-model retry behavior remains green.

Completion evidence:

- Changed files: `lib/picotools/git_commit_model.sh`, `tools/bin/git-commit`, `tests/git-commit-diagnostics.bats`, `tests/git-commit.bats`, `docs/tasks/20260823-145408-git-commit-health-remediation.md`.
- Regression/focused tests: added `tests/git-commit-diagnostics.bats` covering normal-mode suppression of malformed model output containing `SENTINEL_SECRET` and ANSI/control bytes, debug redaction/control escaping/truncation, oversized provider response failure with bounded output, prompt/diagnostic temp cleanup after success and failure, and prompt content absent from model-provider argv; updated exhausted-validation tests to assert raw responses are not printed.
- Command summaries: `bats tests/git-commit-diagnostics.bats` passed, 4 tests; `bats tests/git-commit-modules.bats tests/git-commit-diagnostics.bats` passed, 17 tests; `bats tests/git-commit*.bats` passed, 111 tests after rerun with a 300s timeout; initial 120s full-suite run timed out after reaching test 99/111; `bash -n tools/bin/git-commit lib/picotools/git_commit_model.sh tests/git-commit-diagnostics.bats tests/git-commit.bats` passed; `shellcheck -s bash -x tools/bin/git-commit lib/picotools/git_commit_model.sh tests/git-commit-diagnostics.bats tests/git-commit.bats` passed; `scripts/shfmt-diff.bash` passed with no diff; `git diff --check` passed; `pre-commit run --files docs/tasks/20260823-145408-git-commit-health-remediation.md lib/picotools/git_commit_model.sh tools/bin/git-commit tests/git-commit-diagnostics.bats tests/git-commit.bats` passed.
- Follow-ups: none for DIAG-01. PR lookup/topology hardening remains owned by PR-01.

### Task PR-01: Fail Closed On PR Lookup And Resolve Push Topology Correctly

Status: completed

Priority: P1

Suggested agent: Git remote and GitHub API engineer

Dependencies: SAFE-01, STATE-01

Primary ownership:

- PR/remote functions currently in `tools/bin/git-commit`
- New `lib/picotools/git_commit_remote.sh` and `git_commit_pr.sh` if extracted
- Focused PR tests

Finding:

Existing-PR lookup suppresses command failure and treats authentication, network, rate-limit, server, and malformed-response failures as “no PR,” which can lead to a create attempt after commits are pushed. Repository identity is parsed from the fetch URL, while `git push` can use a different push URL; fork workflows can therefore target the wrong repository or use an unqualified head branch.

References:

- `tools/bin/git-commit:393-434`
- `tools/bin/git-commit:992-1037`
- `tools/bin/git-commit:1149-1297`
- `tools/bin/git-commit:1481-1548`

Implementation requirements:

1. Distinguish successful empty PR lookup from command failure and malformed JSON. Fail before planning/push on unresolved lookup errors unless a documented retry policy succeeds.
2. Resolve effective fetch and push URLs separately and model base repository, head repository owner, branch, and remote explicitly.
3. Qualify fork heads as `<owner>:<branch>` when required and preserve same-repository behavior.
4. Refresh state at the final create/update boundary or handle a concurrent PR creation deterministically.
5. Preserve one-time repository PAT resolution and its precedence over configured/fallback `git-api` authentication.
6. Validate create/update API response shape without leaking response bodies containing sensitive data.

Acceptance criteria:

- A failing `pulls/list` stops before model planning, commit, push, and `pulls/create`.
- Empty successful lookup still creates a PR, while a valid existing result updates it.
- Divergent fetch/push URLs produce the intended base repository and qualified fork head.
- Concurrent-create behavior is deterministic and tested.
- Missing/malformed API fields return precise non-secret errors.
- Repository PAT, configured profile, and fallback auth tests remain green for every API path.

Completion evidence:

- Changed files: `tools/bin/git-commit`, `tests/git-commit-pr.bats`, `tests/git-commit.bats`, `tests/git-commit-state.bats`, `docs/tasks/20260823-145408-git-commit-health-remediation.md`.
- Regression/focused tests: added `tests/git-commit-pr.bats` covering fail-closed `pulls/list` before model/commit/push/create, empty lookup create vs existing lookup update, divergent fetch/push URL base/head resolution with qualified fork heads, final refresh for concurrent PR creation, and precise non-secret malformed list/create response errors; updated existing PR tests for fail-closed update response validation and final lookup auth coverage.
- Command summaries: `bats tests/git-commit-pr.bats` passed, 5 tests; `bats tests/git-commit-pr.bats tests/git-commit.bats` passed, 75 tests; `bats tests/git-commit*.bats` passed, 116 tests after rerun with a 600s timeout; initial 300s full-suite run timed out after test 97/116; `bash -n tools/bin/git-commit tests/git-commit-pr.bats tests/git-commit.bats tests/git-commit-state.bats` passed; `shellcheck -s bash -x tools/bin/git-commit tests/git-commit-pr.bats tests/git-commit.bats tests/git-commit-state.bats` passed; `scripts/shfmt-diff.bash` passed with no diff after indentation fixes; `git diff --check` passed; `pre-commit run --files docs/tasks/20260823-145408-git-commit-health-remediation.md tools/bin/git-commit tests/git-commit-pr.bats tests/git-commit.bats tests/git-commit-state.bats` passed.
- Follow-ups: none for PR-01.

## Wave 4: Architecture, Tests, And Performance

### Task ARCH-01: Extract Stable Domains And Make Dependencies Explicit

Status: completed

Priority: P2

Suggested agent: Bash architecture engineer

Dependencies: SAFE-01, SAFE-02, STATE-01, HOOK-01, PLAN-01, PR-01

Primary ownership:

- `tools/bin/git-commit`
- `lib/picotools/git_commit_*.sh`
- Direct module tests and installed-layout coverage

Finding:

The executable remains a 1,968-line shared hotspot despite three modules. It combines configuration/UI, scope discovery, hooks, prompts, rendering, execution, remotes, PRs, auth, and orchestration. Existing modules have implicit global/callback dependencies, exposed by manual setup in module tests, which limits isolation and makes ownership unclear.

References:

- `tools/bin/git-commit:1-1968`
- `lib/picotools/git_commit_model.sh:1-120`
- `lib/picotools/git_commit_plan.sh:1-263`
- `lib/picotools/git_commit_workspace.sh:1-268`
- `tests/git-commit-modules.bats:51-94`

Implementation requirements:

1. Keep dependency loading, command dispatch, and high-level phase orchestration in the executable.
2. Extract only stable domains established by earlier tasks: options, configuration, scope, hooks, prompts, rendering/execution, and remote/PR behavior as warranted.
3. Give each module an idempotent load guard and an explicit contract for parameters, output, return status, callbacks, and required globals; prefer parameters or scoped state to hidden globals.
4. Remove pass-through wrappers that own no policy.
5. Resolve modules in both repository and installed layouts using existing loader conventions.
6. Add direct tests for pure/isolated behavior while retaining a smaller set of end-to-end contract tests.

Acceptance criteria:

- `tools/bin/git-commit` reads as orchestration rather than mixed domain implementation.
- Every module's dependencies are explicit and its error paths return to the caller rather than unexpectedly terminating the shell.
- Security invariants have one enforcement point each: option parsing, literal/lossless paths, plan validation, index isolation, hook execution, and API response handling.
- Repository and installed layouts load every module and pass an operational preview smoke test with isolated HOME/XDG state.
- Public output changes only where earlier tasks explicitly changed the contract.

Completion evidence:

- Changed files: `tools/bin/git-commit`, `lib/picotools/git_commit_config.sh`, `lib/picotools/git_commit_execution.sh`, `lib/picotools/git_commit_hooks.sh`, `lib/picotools/git_commit_options.sh`, `lib/picotools/git_commit_prompt.sh`, `lib/picotools/git_commit_remote.sh`, `lib/picotools/git_commit_scope.sh`, `lib/picotools/git_commit_model.sh`, `lib/picotools/git_commit_plan.sh`, `lib/picotools/git_commit_workspace.sh`, `tests/git-commit-arch.bats`, `docs/tasks/20260823-145408-git-commit-health-remediation.md`.
- Regression/focused tests: added `tests/git-commit-arch.bats` covering idempotent module loading, direct option parser output/state, module error paths returning to the caller, non-secret PR response validation, repository-layout preview smoke, and installed-layout preview smoke with isolated `HOME`/`XDG_CONFIG_HOME`.
- Command summaries: `bats tests/git-commit-arch.bats` passed, 4 tests; `bats tests/git-commit-arch.bats tests/git-commit-modules.bats` passed, 17 tests; `npm run test:git-commit` passed, 120 tests; `bash -n tools/bin/git-commit lib/picotools/git_commit_*.sh tests/helpers/git-commit.bash` passed; raw `bash -n tests/git-commit.bats` is not a valid Bats syntax check in this environment and fails on existing `@test` syntax; `shellcheck -s bash -x tools/bin/git-commit lib/picotools/git_commit_*.sh tests/git-commit*.bats tests/helpers/git-commit.bash` passed; `scripts/shfmt-diff.bash` passed with no diff; `git diff --check` passed; `pre-commit run --files docs/tasks/20260823-145408-git-commit-health-remediation.md tools/bin/git-commit lib/picotools/git_commit_model.sh lib/picotools/git_commit_plan.sh lib/picotools/git_commit_workspace.sh lib/picotools/git_commit_config.sh lib/picotools/git_commit_execution.sh lib/picotools/git_commit_hooks.sh lib/picotools/git_commit_options.sh lib/picotools/git_commit_prompt.sh lib/picotools/git_commit_remote.sh lib/picotools/git_commit_scope.sh tests/git-commit-arch.bats` passed.
- Follow-ups: none for ARCH-01. PERF-01 and DOC-CI-01 remain pending as separate tasks.

### Task TEST-01: Split Fixtures And Tests Along Stable Boundaries

Status: completed

Priority: P2

Suggested agent: Bats test architecture engineer

Dependencies: SAFE-01; stable module boundaries from ARCH-01 preferred for final split

Primary ownership:

- `tests/git-commit.bats`
- `tests/git-commit-modules.bats`
- New `tests/helpers/git-commit.bash` and focused `tests/git-commit-*.bats` files
- `package.json`

Finding:

The 2,959-line integration test file mixes approximately 643 lines of assertions, stubs, and fixtures with all scenarios. It duplicates production preview quoting and maintains a partial Python `jq`, while module tests use real `jq`. This can reproduce implementation bugs in expected output and makes parallel ownership difficult.

References:

- `tests/git-commit.bats:1-643`
- Preview duplication: `tests/git-commit.bats:54-84` and `tools/bin/git-commit:1717-1741`
- Partial `jq`: `tests/git-commit.bats:224-374`
- Real `jq` setup: `tests/git-commit-modules.bats:3-17`
- `package.json:15-20`

Implementation requirements:

1. Extract shared assertions, stubs, repository builders, and isolated HOME/XDG setup into one helper.
2. Split scenarios by stable concern: options, workspace/paths, hooks, plans/model, apply/state, and PR/remotes.
3. Use real `jq` for production behavior; keep stubs only for explicit missing-command or invocation tests.
4. Capture security-sensitive subprocess arguments losslessly, one argument per record or with NUL delimiters, never flattened through `$*`.
5. Test preview output by decoding/asserting argv semantics rather than reimplementing production quoting.
6. Add `test:git-commit` to run every focused Git commit suite while retaining `bats tests/*.bats` compatibility.

Acceptance criteria:

- `npm run test:git-commit` runs every Git commit test file.
- Test count and behavior coverage do not regress.
- Security tests distinguish one argument containing spaces from multiple arguments.
- No test depends on ordering or leaves repositories, credentials, hooks, or temporary files outside Bats-owned directories.
- Agents can own focused test files without concurrent edits to one monolith.

Completion evidence:

- Changed files: `package.json`, `tests/helpers/git-commit.bash`, `tests/git-commit.bats`, `tests/git-commit-modules.bats`, `tests/git-commit-options.bats`, `tests/git-commit-paths.bats`, `tests/git-commit-hooks.bats`, `tests/git-commit-state.bats`, `tests/git-commit-pr.bats`, `tests/git-commit-diagnostics.bats`, `docs/tasks/20260823-145408-git-commit-health-remediation.md`.
- Regression/focused tests: extracted shared Git commit test setup/assertions/repository/config helpers into `tests/helpers/git-commit.bash`; kept existing focused suites as ownership boundaries; added `npm run test:git-commit`; switched legacy jq stubs to real jq links where production behavior is exercised; changed subprocess arg logs to include lossless per-argument records; added a path assertion that `:(top,literal)space name.txt` is one argv item and not split into `:(top,literal)space` plus `name.txt`; preview add expectations call the production renderer instead of duplicating quoting logic.
- Command summaries: `npm run test:git-commit` passed, 116 tests; `bats tests/*.bats` passed, 383 tests; `bash -n tests/helpers/git-commit.bash tests/git-commit*.bats` passed; `shellcheck -s bash -x tests/helpers/git-commit.bash tests/git-commit*.bats` passed after targeted suppressions for intentional helper-provided jq variables and unreachable legacy jq fallback bodies; `scripts/shfmt-diff.bash` passed with no diff; `git diff --check` passed; `pre-commit run --files docs/tasks/20260823-145408-git-commit-health-remediation.md package.json tests/helpers/git-commit.bash tests/git-commit.bats tests/git-commit-modules.bats tests/git-commit-options.bats tests/git-commit-paths.bats tests/git-commit-hooks.bats tests/git-commit-state.bats tests/git-commit-pr.bats tests/git-commit-diagnostics.bats` passed.
- Follow-ups: none for TEST-01.

### Task PERF-01: Measure And Reduce Git And Jq Process Churn

Status: completed

Priority: P3

Suggested agent: Bash performance engineer

Dependencies: PATH-01, PLAN-01, ARCH-01

Primary ownership:

- Reproducible benchmark fixture
- Workspace and normalized-plan modules
- Production code only for measured improvements

Finding:

Diff collection launches Git processes per changed file, plan rendering/execution repeatedly invokes `jq`, and file resolution repeatedly scans the complete changed-file list. Prompt output is capped, but process launches continue until the budget is exceeded. The impact is plausible for thousands of changed files but has not been measured.

References:

- `lib/picotools/git_commit_workspace.sh:161-244`
- `lib/picotools/git_commit_plan.sh:109-224`
- `tools/bin/git-commit:957-989`
- `tools/bin/git-commit:1039-1092`
- `tools/bin/git-commit:1743-1858`

Implementation requirements:

1. Add a reproducible benchmark for 10, 1,000, and 10,000 changed files, including subprocess counts and wall-clock time.
2. Record baseline before changing production behavior.
3. Measure batched diff collection, one-time normalized JSON parsing, lookup maps, and early prompt-budget termination separately.
4. Preserve all path, schema, truncation, and exact-once invariants from earlier tasks.
5. Retain only changes with a material documented improvement; otherwise mark this task deferred with evidence.

Acceptance criteria:

- Benchmark commands, environment, baseline, and after-results are recorded in this task.
- Any retained optimization materially lowers process count and wall-clock time at representative scale.
- Focused and full test results are unchanged.
- If no safe material gain exists, no production optimization is retained and residual cost is documented.

Completion evidence:

- Changed files: `scripts/benchmark-git-commit-perf.bash`, `lib/picotools/git_commit_workspace.sh`, `docs/tasks/20260823-145408-git-commit-health-remediation.md`.
- Benchmark fixture/command: added `scripts/benchmark-git-commit-perf.bash`; it creates disposable repositories with `GIT_COMMIT_PERF_SIZES="10 1000 10000"`, wraps `git` and `jq` to count subprocess invocations during measured sections, and prints `mode,size,wall_ms,git_processes,jq_processes,status`. Baseline command before production edits: `scripts/benchmark-git-commit-perf.bash`, followed by `GIT_COMMIT_PERF_SIZES="10000" GIT_COMMIT_PERF_MODES="lookup-linear lookup-map" scripts/benchmark-git-commit-perf.bash` because the full baseline command hit the 900s tool timeout after completing 10k plan normalization and before the 10k lookup rows. After command for retained optimization: `GIT_COMMIT_PERF_MODES="diff-current diff-current-budget diff-untracked-map-candidate diff-batched-candidate" scripts/benchmark-git-commit-perf.bash`.
- Benchmark environment: `/home/jahn/projects/_picotools`; Bash `5.2.21(1)-release`; Git `2.43.0`; jq `1.8.2`; temp repositories under `/tmp/git-commit-perf.*`; generated tracked modified files named `files/file-NNNNN.txt`; default production prompt limits unless the `diff-current-budget` mode explicitly set `MAX_COMMIT_PLAN_DIFF_CHARS=2000`.
- Baseline results before production edits: `diff-current` was 10 files `254ms`, 26 Git, 0 jq; 1000 files `4528ms`, 556 Git, 0 jq; 10000 files `6646ms`, 556 Git, 0 jq. `diff-untracked-map-candidate` was 10 files `148ms`, 17 Git; 1000 files `2778ms`, 282 Git; 10000 files `3601ms`, 282 Git. `diff-batched-candidate` was 10 files `77ms`, 5 Git; 1000 files `1559ms`, 5 Git; 10000 files `63851ms`, 5 Git. `diff-current-budget` was 10 files `220ms`, 26 Git; 1000 files `235ms`, 28 Git; 10000 files `607ms`, 28 Git. `plan-current` was 10 files `543ms`, 0 Git, 31 jq; 1000 files `17451ms`, 0 Git, 1021 jq; 10000 files `482466ms`, 0 Git, 10021 jq. `plan-normalized-candidate` was 10 files `26ms`, 0 Git, 1 jq; 1000 files `30ms`, 0 Git, 1 jq; 10000 files `47ms`, 0 Git, 1 jq. Lookup results were 10 linear/map `20ms`/`21ms`, 1000 linear/map `3288ms`/`32ms`, 10000 linear/map `341290ms`/`178ms`, all 0 Git and 0 jq.
- Retained production optimization: `collect_changes_diff` now builds one untracked-file lookup map with `git ls-files -z --others --exclude-standard` and uses it to choose the existing added-file vs tracked-file diff helpers, removing the previous per-file `git ls-files --error-unmatch` process while preserving literal pathspecs, NUL-safe filenames, per-file omission, and prompt-budget termination behavior. The fully batched diff candidate was not retained because it was slower at 10000 files in this fixture and would not preserve the current per-file diff omission boundary without additional complexity. Normalized JSON parsing remains a measured follow-up rather than a production change because it would require a larger plan data-model change outside this P3 safe-retention threshold.
- After results for retained path: `diff-current` was 10 files `111ms`, 17 Git, 0 jq; 1000 files `2351ms`, 282 Git, 0 jq; 10000 files `4045ms`, 282 Git, 0 jq. `diff-current-budget` was 10 files `113ms`, 17 Git; 1000 files `169ms`, 18 Git; 10000 files `484ms`, 18 Git. These retain a material representative-scale reduction versus baseline: 1000 files reduced 556 -> 282 Git processes and 4528ms -> 2351ms; 10000 files reduced 556 -> 282 Git processes and 6646ms -> 4045ms.
- Verification: `npm run test:git-commit` passed, 120 tests; `bats tests/*.bats` passed, 387 tests; `bash -n scripts/benchmark-git-commit-perf.bash lib/picotools/git_commit_workspace.sh` passed; `shellcheck -s bash -x scripts/benchmark-git-commit-perf.bash lib/picotools/git_commit_workspace.sh` passed; `scripts/shfmt-diff.bash` passed with no diff; `git diff --check` passed; `pre-commit run --files docs/tasks/20260823-145408-git-commit-health-remediation.md lib/picotools/git_commit_workspace.sh scripts/benchmark-git-commit-perf.bash` passed.
- Residual risk/follow-ups: plan validation/rendering still performs repeated `jq` parsing at very large plan sizes, documented by the 10000-file `plan-current` baseline; a future task can introduce normalized plan data if the larger contract change is warranted. Added-file diff generation remains per file; this is preserved intentionally to keep current oversized-added-file behavior and exact prompt semantics.

## Wave 5: Public Contract And Independent Review

### Task DOC-CI-01: Align Documentation Packaging And CI Checks

Status: completed

Priority: P2

Suggested agent: documentation and CI engineer

Dependencies: SAFE-01, SAFE-02, PATH-01, STATE-01, HOOK-01, PLAN-01, DIAG-01, PR-01, ARCH-01, TEST-01

Primary ownership:

- `README.md`
- `usage()` in `tools/bin/git-commit`
- `package.json`
- `.github/workflows/test.yml`
- `.github/workflows/pre-commit.yml`
- `scripts/shellcheck.bash` if retained

Finding:

The complete safety and failure contract is compressed into one README paragraph. Installed CI checks only `git-commit --help` and `--version`; syntax validation omits `lib/picotools/*.sh`; pre-commit on pull requests is filtered to Markdown/workflow changes; and `scripts/shellcheck.bash` checks only top-level `bin/*`.

References:

- `README.md:51`
- `package.json:15-20`
- `.github/workflows/test.yml:3-31`
- `.github/workflows/test.yml:33-109`
- `.github/workflows/pre-commit.yml:3-9`
- `scripts/shellcheck.bash:1-3`

Implementation requirements:

1. Document configuration, preview/apply, scope/path encoding, hook execution, stale-plan behavior, partial failures/recovery, push/PR topology, and auth precedence in readable subsections.
2. Keep help, README, implementation, and tests aligned on every changed contract.
3. Ensure shellcheck, syntax, and read-only formatting checks cover executable, modules, helpers, and relevant Bats files on pull requests.
4. Add an installed-layout operational `git-commit` preview smoke test using isolated HOME/XDG state, a temporary repository, and stubbed model provider without credentials or network access.
5. Verify all newly extracted modules are packaged.

Acceptance criteria:

- Public documentation clearly states when repository code executes and what preview/apply can mutate.
- The installed archive completes a non-destructive planned preview using its installed modules.
- Code-only pull requests run relevant lint and focused tests.
- `npm run test:git-commit`, repository-wide tests, syntax checks, formatting checks, and pre-commit pass.

Completion evidence:

- Changed files: `README.md`, `tools/bin/git-commit`, `package.json`, `.github/workflows/test.yml`, `.github/workflows/pre-commit.yml`, `scripts/shellcheck.bash`, `docs/tasks/20260823-145408-git-commit-health-remediation.md`.
- Documentation updates: split the `git-commit` public contract into readable README subsections for configuration, preview/apply mutations, scope/path encoding, repository-controlled hook execution, stale-plan rejection, partial failure/recovery, push/PR topology, and PR authentication precedence; expanded `git-commit --help` with the same preview/apply, path, hook, stale-plan, recovery, topology, and auth contracts.
- CI/package updates: added `check:syntax`, `check:shellcheck`, and `check:format` npm scripts; expanded `scripts/shellcheck.bash` to cover regular files under `bin`, `tools/bin`, `lib/picotools`, `scripts`, `tests/helpers`, and Bats tests; removed PR path filtering from pre-commit so code-only PRs run it; made the test workflow run `npm run test:git-commit`, repository Bats, syntax, shellcheck, format checks, installed module packaging assertions, and an installed-layout non-destructive `git-commit` preview smoke with isolated `HOME`/`XDG_*` and a stubbed `MODEL_PROFILE_BIN` provider.
- Command summaries: `npm run test:git-commit` passed, 120 tests; `npm test` passed, 387 tests; `npm run check:syntax` passed; `npm run check:shellcheck` passed after filtering directory globs to regular files; `npm run check:format` passed; `pre-commit run --all-files` passed after fixing workflow heredoc YAML indentation; local installed-archive smoke equivalent passed from `/tmp/opencode`, verified all `git_commit_*.sh` modules in the installed layout, rendered a planned preview, left the index unstaged, and kept `HEAD` at one commit.
- Follow-ups: none for DOC-CI-01. Earlier smoke attempts exposed two DOC-CI-01 issues and were fixed before completion: the installed tool resolved sibling `model-profile` unless `MODEL_PROFILE_BIN` was pinned to the stub, and the workflow heredoc body needed valid YAML indentation.

### Task REVIEW-01: Perform Independent Security And Integration Review

Status: completed

Priority: P0

Suggested agent: independent Bash/Git security reviewer not used for implementation

Dependencies: all tasks above; PERF-01 may be completed or explicitly deferred

Primary ownership:

- Review only, plus narrowly scoped fixes/tests for discovered regressions
- Completion evidence in this document

Finding:

The remediation crosses destructive local Git operations, repository-controlled hooks, model input/output, token-mediated API calls, push/PR side effects, filename encoding, module packaging, and CI. An independent reviewer must verify runtime behavior and final contracts rather than implementation shape alone.

References:

- Every finding and acceptance criterion in this document
- `docs/tasks/20260818-212431-repository-git-profile-pat-auth.md`
- `docs/tasks/20260823-120246-git-profile-health-remediation.md`

Implementation requirements:

1. Reproduce parser fail-open, literal-pathspec, stale-index/content, scoped-hook, hook-CWD, unborn-index, invalid-plan, diagnostic leakage, failed-PR-lookup, and divergent-remote cases against the final implementation.
2. Verify exact planned files across previews, preliminary hooks, real hooks, commits, pushes, and PR operations.
3. Verify unusual valid Git filenames and every documented unsupported boundary.
4. Verify no PAT or source/model secret sentinel crosses argv, logs, errors, task evidence, or retained temporary files.
5. Verify public help/README, tests, implementation, and installed behavior agree.
6. Review every deferred item for rationale and residual risk.
7. Record unrelated pre-existing failures exactly; never mask or revert them.

Acceptance criteria:

- Every prior task has runtime or test evidence for each acceptance criterion.
- `npm run test:git-commit` passes.
- `bats tests/*.bats` passes.
- `bash -n bin/* tools/bin/* lib/picotools/*.sh scripts/*.bash` passes, adjusted for the final module layout.
- `scripts/shfmt-diff.bash` reports no diff.
- `pre-commit run --all-files` passes, or unrelated pre-existing failures are recorded exactly.
- The installed archive passes the operational Git commit smoke test.
- No secret-bearing or task-created temporary artifact remains in the worktree.

Completion evidence:

- Review coverage: independently reviewed final parser/options, workspace path collection and literal pathspec conversion, lossless JSON/path handling, plan validation/retry boundary, model diagnostic redaction/temp-file handling, preliminary hook temporary-index behavior, stale-plan/index revalidation, isolated commit creation, push/PR topology and API response validation, installed module resolution, README/help/CI alignment, and every prior task's evidence against its acceptance criteria.
- Runtime coverage verified by focused and full suites: parser fail-closed, missing/invalid options, exact mixed path ordering, literal glob/metacharacter/leading-colon/space pathspecs, unusual valid filenames including newline/tab/backslash/quote/non-ASCII, deleted/renamed paths, stale content/path/index rejection, scoped preliminary hooks, hook repository-root CWD, unborn initial commit, split-index unsupported boundary, invalid plan schema/semantics/retry, bounded non-secret diagnostics, failed PR lookup fail-closed, divergent fetch/push remote topology, concurrent PR creation, auth precedence, push/PR failure state, repository and installed layout preview smoke.
- Changed files from REVIEW-01: `.github/workflows/test.yml`, `docs/tasks/20260823-145408-git-commit-health-remediation.md`. Narrow fixes: the installed-layout CI smoke now links the real `jq` binary into the isolated smoke `PATH`, avoiding local asdf-shim failures when `HOME` is intentionally isolated; the preview assertion now checks the actual rendered `git add -A --` command.
- Command summaries: `npm run test:git-commit` passed, 120 tests; `bats tests/*.bats` passed, 387 tests; `npm run check:syntax` passed; `scripts/shfmt-diff.bash` passed with no diff; `git diff --check` passed; `pre-commit run --all-files` passed before and after the CI-smoke fixes; installed archive `git-commit` preview smoke passed from `/tmp/opencode` with installed modules, isolated `HOME`/`XDG_*`, stubbed model provider, real `jq` on isolated `PATH`, workflow-equivalent preview assertions, no staging, and `HEAD` remaining at one commit.
- Exact blocker/fix evidence: initial local installed-smoke reproduction failed because isolated `HOME` made `jq` resolve to a non-executable local asdf shim, causing plan parse checks to return status 126 despite valid model JSON. Final workflow assertion review also found the CI smoke was grepping `git add --` while the implementation renders `git add -A --`. Both were adjusted in `.github/workflows/test.yml`, and the workflow-equivalent smoke passed afterward.
- Residual risk: no implementation security regressions found. The performance task intentionally left very large plan normalization as a documented future optimization; added-file diff collection remains per-file to preserve current prompt semantics. Existing non-review `/tmp/opencode/git-commit-install-smoke.*` directories predated this review and were not modified. No REVIEW-01-created temp, `tmp`, or `dist` artifact remains in the worktree or `/tmp/opencode`.

## Dependencies And Parallelization

| Wave | Tasks | Parallelization guidance |
| --- | --- | --- |
| 1 | SAFE-01, SAFE-02, PATH-01 | Start SAFE-01 first. SAFE-02 follows its stable option/path interface. PATH-01 follows both because it changes the internal filename representation. |
| 2 | STATE-01, HOOK-01 | May run in parallel only after literal path handling is stable and only if they own separate extracted modules/test files. Both currently touch executable/test hotspots, so serialize otherwise. |
| 3 | PLAN-01, DIAG-01, PR-01 | PLAN-01 and PR-01 may run in parallel with separate tests. DIAG-01 follows PLAN-01. PR-01 follows STATE-01 because it must honor final side-effect sequencing. |
| 4 | ARCH-01, TEST-01, PERF-01 | Land fixture extraction early if it is behavior-neutral. Final architecture follows behavioral contracts. Performance follows normalized path/plan representations. |
| 5 | DOC-CI-01, REVIEW-01 | Documentation/CI follows finalized behavior. Independent review is last. |

Shared hotspots requiring serialization until extraction:

- `tools/bin/git-commit`
- `tests/git-commit.bats`
- `lib/picotools/git_commit_workspace.sh` for SAFE-02 and PATH-01
- `lib/picotools/git_commit_plan.sh` for PATH-01 and PLAN-01
- `.github/workflows/test.yml` and `package.json` for TEST-01 and DOC-CI-01

Recommended agent allocation:

| Agent | Primary tasks |
| --- | --- |
| A: CLI/path safety | SAFE-01, SAFE-02 |
| B: Git data model | PATH-01 |
| C: Git state/hooks | STATE-01, HOOK-01, serialized if hotspots remain |
| D: Model contract | PLAN-01, DIAG-01 |
| E: Remote/API | PR-01 |
| F: Architecture/tests | TEST-01, then ARCH-01 with completed behavior contracts |
| G: Performance | PERF-01 only after architecture stabilizes |
| H: Docs/CI | DOC-CI-01 |
| I: Independent reviewer | REVIEW-01 only |

## Deferred Decisions Requiring Maintainer Input

1. Preliminary hooks in preview mode: recommended behavior is to skip repository-controlled hooks unless `--apply` or a new explicit check flag is present. If preview must continue running hooks, help/output must warn before execution and tests must define permitted worktree mutations. This decision blocks HOOK-01's final public contract, not SAFE-01 or SAFE-02.
2. Automatic rollback after partial local apply: recommended behavior is fail-safe index isolation plus explicit recovery guidance, not automatic history rewriting. Any stronger rollback contract must distinguish local commits from already-pushed state.
3. Fuzzy model path resolution: recommended behavior is exact repository-relative paths only after PATH-01. Retain basename/suffix compatibility only if an external consumer requirement is identified and ambiguity remains fail-closed.

## Definition Of Done

- P0 tasks SAFE-01, SAFE-02, and STATE-01 are completed with regressions that fail against the reviewed baseline.
- Hook execution and partial-failure contracts are documented and tested.
- Every Git filename reaches Git through a lossless, literal operand boundary.
- Model and API failures are bounded, non-secret, and fail before unintended local or remote side effects.
- Exact planned file partitioning is preserved across preliminary hooks, real hooks, commits, pushes, and PR operations.
- Stable domains have explicit ownership and dependencies; the executable is primarily orchestration.
- Focused tests can run by domain and the installed archive exercises an operational preview.
- Performance changes are supported by before/after evidence or explicitly deferred without production churn.
- Independent review and all repository-correct verification commands pass, with any unrelated pre-existing failure recorded precisely.
