# Git Profile Health Remediation

Created: 2026-08-23 12:02:46 -0700

## Objective

Harden `git-profile` against unsafe filesystem state and partial mutations, make its persisted profile schema and CLI contract explicit, and then improve readability, reuse, testability, and measured performance without changing unrelated tools or weakening the repository-aware PAT behavior completed in `docs/tasks/20260818-212431-repository-git-profile-pat-auth.md`.

## Scope

- `tools/bin/git-profile`
- `tests/git-profile.bats`
- New tool-specific modules under `tools/lib/picotools/git-profile/` when extraction is justified
- `lib/picotools/prompt.sh` and its consumers/tests only for the shared EOF defect
- `README.md` and `tools/bin/git-profile` help text for changed contracts
- `.github/workflows/test.yml` and `.github/workflows/pre-commit.yml` for installed-layout and documentation checks

## Working Rules And Non-Goals

- Preserve unrelated concurrent work. Inspect `git status --short` before each task and never revert changes owned by another agent.
- Serialize tasks that modify `tools/bin/git-profile` or `tests/git-profile.bats`.
- Keep token bytes out of arguments, Git config, debug logs, tables, errors, test names, and committed fixtures.
- Preserve `git-profile token` stdout and expected fallback errors consumed by `tools/bin/git-commit:1395-1421`; coordinate changes with `tests/git-commit.bats` if those exact errors change.
- Preserve existing profiles as persisted user data. Schema changes need a narrow legacy read path, not silent breakage.
- Do not create a generic framework for all picotools. Extract only cohesive `git-profile` behavior after its contracts are stable.
- Do not optimize table rendering or shared libraries without measurements showing that `git-profile` benefits.
- OS keyring integration and encrypted-at-rest PAT storage remain out of scope.

## Confirmed Baseline

- `git-profile` is one 1,548-line executable covering persistence, secret storage, prompts, rendering, SSH/GPG lifecycle, repository mutation, cloning, and dispatch (`tools/bin/git-profile:1-1548`).
- Its focused test suite is one 1,632-line Bats file with shared fixtures and 46 scenarios (`tests/git-profile.bats:1-1632`).
- The prior repository-profile/PAT task is complete and records its security and compatibility contracts in `docs/tasks/20260818-212431-repository-git-profile-pat-auth.md`.
- Release and install layouts already include `tools/lib`, so tool-specific modules can be packaged without changing archive structure (`.github/workflows/test.yml:37-46`).
- The repository Bash convention requires direct shared-module declarations, command checks, matching Bats coverage, syntax validation, formatting, and pre-commit (`.opencode/skills/bash-tool-conventions/SKILL.md`).
- Worktree at review time was clean (`git status --short` produced no output).

## Baseline Verification

Run on 2026-08-23 before creating this task:

- `bats tests/git-profile.bats`: 46 passed.
- `bash -n tools/bin/git-profile tests/git-profile.bats`: passed.
- `shellcheck tools/bin/git-profile tests/git-profile.bats`: passed.
- `git diff --check`: passed.
- Two independent source reviews also ran focused probes that confirmed the parent-directory symlink traversal, hard-link overwrite, partial create/update/delete behavior, SSH path decoding failure, ignored token arguments, permissive PAT read, and missing-GPG-status diagnostic described below.
- Full `bats tests/*.bats` and `pre-commit run --all-files` were not rerun for this review because only this task document was created.

## Priorities

- P0: Confirmed secret disclosure/deletion paths or irreversible partial state.
- P1: Confirmed correctness defects, invalid persisted state, and unsafe command boundaries.
- P2: CLI consistency, dependency handling, documentation, and CI coverage.
- P3: Optional architectural or performance improvement requiring evidence.

## Wave 1: Security And State Integrity

### Task SEC-01: Make PAT Storage Path-Safe And Atomic

Status: completed

Priority: P0

Suggested agent: Bash filesystem security engineer

Dependencies: none

Primary ownership:

- `tools/bin/git-profile`
- Focused PAT tests in `tests/git-profile.bats`

Finding:

The token leaf is rejected when it is a symlink, but read and delete never validate the data directory itself. A symlink at `${XDG_DATA_HOME}/git-profile` is therefore followed for token status, read, and delete. Writes also redirect into an existing non-symlink token path, so a hard-linked regular file is overwritten and a FIFO can disclose the PAT or block the process. Reads accept mode-`0644` token files in mode-`0755` directories despite the documented `0700`/`0600` contract, and multiline files are silently concatenated by `tr -d '\r\n'`.

References:

- `tools/bin/git-profile:99-105`
- `tools/bin/git-profile:121-157`
- `tools/bin/git-profile:170-221`
- `tests/git-profile.bats:1324-1392`
- `tests/git-profile.bats:1428-1632`
- `README.md:43`

Implementation requirements:

1. Add regression tests for a symlinked data directory across status/list, token read, write/update, and delete; assert no outside file is read, modified, or removed.
2. Reject non-regular token destinations, including FIFO/socket/device paths, and prevent writes through pre-existing hard links.
3. Stage PAT content in a newly created same-directory mode-`0600` regular file and publish it atomically without following an unsafe destination.
4. Apply one shared path-validation boundary to status, read, write, and delete instead of duplicating leaf checks.
5. Reject malformed multiline token content; strip only the expected trailing line ending.
6. Implement the maintainer-selected read-time permission policy from Deferred Decisions consistently for status, token retrieval, update, and delete.
7. Preserve the existing missing/blank PAT behavior and non-disclosure contract.

Acceptance criteria:

- A symlinked data directory cannot cause `list`, `read`, `token`, `create`, `update`, or `delete` to access a target outside the configured data root.
- Replacing a token whose destination is hard-linked leaves the other link unchanged and fails safely or atomically replaces only the directory entry.
- FIFO and other non-regular destinations fail without blocking or disclosing a token; the regression test is timeout-bounded.
- A failed write leaves the previous token intact and no temporary file behind.
- Permission and multiline-file behavior matches the documented policy.
- Token sentinels are absent from command output and committed artifacts.
- `bats tests/git-profile.bats` and `pre-commit run --files tools/bin/git-profile tests/git-profile.bats` pass.

Completion evidence:

- Changed files: `tools/bin/git-profile`, `tests/git-profile.bats`, `README.md`, `docs/tasks/20260823-120246-git-profile-health-remediation.md`.
- Implemented one PAT storage boundary that rejects symlinked/non-directory data roots, symlinked/non-regular token leaves, permissive read/status/delete modes, and malformed multiline token files.
- Implemented explicit-write repair for safe PAT writes and same-directory mode-`0600` temporary-file publishing via atomic rename, preserving token stdout/fallback behavior.
- Added regressions for symlinked data directories across `list`, `read`, `token`, `create`, `update`, and `delete`; hard-link replacement; FIFO rejection with `timeout 5`; fail-closed permissions; multiline token rejection; and no leftover token temporaries.
- `bash -n tools/bin/git-profile tests/git-profile.bats`: passed.
- `bats tests/git-profile.bats`: 51 passed.
- `shellcheck tools/bin/git-profile tests/git-profile.bats`: passed.
- `pre-commit run --files tools/bin/git-profile tests/git-profile.bats`: passed.
- `pre-commit run --files tools/bin/git-profile tests/git-profile.bats README.md docs/tasks/20260823-120246-git-profile-health-remediation.md`: passed.
- Follow-up/blocker: none for SEC-01.

### Task STATE-01: Make Profile And Token Updates Failure-Safe

Status: completed

Priority: P0

Suggested agent: Bash transactional-storage engineer

Dependencies: SEC-01

Primary ownership:

- `tools/bin/git-profile`
- Profile create/update failure tests in `tests/git-profile.bats`

Finding:

`save_context` removes the existing profile and reconstructs it with separate `git config` processes. Create and update commit that profile before the PAT operation, so a later PAT failure returns nonzero after changing profile state. A write failure or signal during reconstruction can leave an absent or partial profile. Generated SSH/GPG resources are also not tracked for cleanup if a later create step fails.

References:

- `tools/bin/git-profile:738-821`
- `tools/bin/git-profile:844-890`
- `tools/bin/git-profile:892-970`
- `tools/bin/git-profile:1200-1335`
- `tests/git-profile.bats:458-615`
- `tests/git-profile.bats:617-765`
- `tests/git-profile.bats:1554-1572`

Implementation requirements:

1. Add failure-injection tests proving failed create leaves no new profile and failed update preserves the complete previous profile and token.
2. Build a complete candidate profile in a same-directory temporary file, validate it, enforce its mode, and atomically rename it instead of removing and rebuilding the live file.
3. Preflight PAT storage before publishing profile changes and define rollback ordering for the two-file profile/PAT state.
4. Track only SSH/GPG material generated by the current invocation and apply the maintainer-selected rollback policy; never delete user-supplied existing key material on create failure.
5. Register cleanup once and remove all transaction temporary files on success, failure, and signals handled by the script.
6. Preserve old profiles that omit newer managed keys by continuing to apply documented defaults.

Acceptance criteria:

- Every injected profile-write or PAT-write failure preserves the complete pre-operation profile and token.
- A failed new create publishes neither profile nor token.
- Successful create/update exposes complete files only, with no `.lock` or task-owned temporary files left behind.
- Generated-material behavior is documented and covered separately from user-supplied material.
- Existing create, update, token, and backward-default tests remain green.
- `bats tests/git-profile.bats` passes.

Completion evidence:

- Changed files: `tools/bin/git-profile`, `tests/git-profile.bats`, `docs/tasks/20260823-120246-git-profile-health-remediation.md`.
- Implemented same-directory candidate profile files with validation, mode enforcement, atomic rename, cleanup trap registration, and profile snapshot/restore for create/update transactions.
- Added PAT preflight before profile publish and rollback ordering that restores the previous profile when PAT write/delete fails; failed new create removes the new profile and leaves no token.
- Added current-invocation generated-material rollback behavior: generated SSH private/public files are removed on failed create; generated GPG keys are retained and the generated fingerprint is reported for manual recovery; user-supplied SSH material is preserved.
- Added failure-injection tests for failed create after generated SSH/GPG material and unsafe PAT storage, failed update candidate profile write, failed update PAT publish, temp cleanup, and user-supplied SSH preservation.
- `bash -n tools/bin/git-profile tests/git-profile.bats`: passed.
- `git diff --check`: passed.
- `bats tests/git-profile.bats --filter 'failed create removes generated SSH material|failed update PAT write rolls back'`: 2 passed.
- `bats tests/git-profile.bats`: 54 passed.
- `shellcheck tools/bin/git-profile tests/git-profile.bats`: passed.
- `pre-commit run --files tools/bin/git-profile tests/git-profile.bats docs/tasks/20260823-120246-git-profile-health-remediation.md`: passed.
- Follow-up/blocker: none for STATE-01.

### Task STATE-02: Preflight Destructive Profile Deletion

Status: completed

Priority: P0

Suggested agent: destructive-operation safety engineer

Dependencies: SEC-01

Primary ownership:

- `tools/bin/git-profile`
- Delete tests in `tests/git-profile.bats`

Finding:

Deletion can remove a GPG key and SSH key files before validating/deleting the PAT and profile. If the PAT path is unsafe, the command fails after irreversible external material is gone while the profile remains and points to missing keys.

References:

- `tools/bin/git-profile:1071-1118`
- `tests/git-profile.bats:285-325`
- `tests/git-profile.bats:1605-1632`

Implementation requirements:

1. Add a regression combining SSH/GPG deletion approval with a failing PAT preflight and assert no material is removed.
2. Validate all owned paths and collect all confirmations before the first mutation.
3. Delete profile-owned PAT/profile state as one planned operation before optional external key material, or clearly separate external cleanup into a post-delete phase whose failures cannot leave a live profile pointing at removed resources.
4. Use option-safe command boundaries for file and GPG deletion; reject malformed or option-like signing identifiers before invoking GPG.
5. Preserve explicit confirmation for SSH and GPG deletion.

Acceptance criteria:

- Any preflight failure leaves profile, PAT, SSH files, and GPG material unchanged.
- Dash-leading or malformed SSH/GPG identifiers cannot become command options.
- Successful deletion removes the profile and PAT and performs only the external deletions explicitly confirmed by the user.
- Failure after profile-owned state is removed reports precise partial-cleanup status without recreating inconsistent state.
- Focused delete tests and `bats tests/git-profile.bats` pass.

Completion evidence:

- Changed files: `tools/bin/git-profile`, `tests/git-profile.bats`, `docs/tasks/20260823-120246-git-profile-health-remediation.md`.
- Reordered profile deletion so profile/PAT state is preflighted before mutation, profile-owned state is removed before optional SSH/GPG cleanup, and post-delete external cleanup failures report precise partial-cleanup errors without restoring inconsistent profile state.
- Added option-safe deletion/invocation boundaries with `rm --`, GPG `--` operand separation, and validation that rejects dash-leading or malformed GPG signing identifiers before GPG invocation or profile mutation.
- Added focused regressions for PAT preflight failure preserving profile/PAT/SSH/GPG material, dash-leading and malformed GPG identifiers, and dash-leading SSH key deletion operands.
- `bash -n tools/bin/git-profile tests/git-profile.bats`: passed.
- `bats tests/git-profile.bats --filter 'delete'`: 8 passed.
- `bats tests/git-profile.bats`: 58 passed.
- `shellcheck tools/bin/git-profile tests/git-profile.bats`: passed.
- `git diff --check`: passed.
- `pre-commit run --files tools/bin/git-profile tests/git-profile.bats docs/tasks/20260823-120246-git-profile-health-remediation.md`: passed.
- Follow-up/blocker: none for STATE-02.

## Wave 2: Schema And Behavioral Correctness

### Task SCHEMA-01: Define And Validate Complete Profile State

Status: completed

Priority: P1

Suggested agent: Git configuration contract engineer

Dependencies: STATE-01

Primary ownership:

- `tools/bin/git-profile`
- Profile validation and repository-set tests in `tests/git-profile.bats`

Finding:

Create permits blank identity values, update accepts arbitrary strings for boolean and enum settings, and `apply_context` mutates repository config one key at a time before the complete saved profile is known to be valid. A malformed profile can therefore poison saved/local Git config or leave a repository partially switched.

References:

- `tools/bin/git-profile:380-447`
- `tools/bin/git-profile:844-890`
- `tools/bin/git-profile:913-948`
- `tools/bin/git-profile:1138-1179`
- `tools/bin/git-profile:1212-1277`
- `tests/git-profile.bats:617-914`

Implementation requirements:

1. Define the managed fields, defaults, required fields, and accepted Git-compatible domains in one schema-aware boundary.
2. Validate a complete create/update candidate before publishing it and validate a complete saved profile before changing repository-local config.
3. Cover Git-supported values rather than reducing fields to inaccurate booleans; explicitly enumerate `push.default` and supported `pull.rebase` forms.
4. Read all source values before the first local repository write and preserve the repository unchanged when validation fails.
5. Decide and document whether saved profile files are tool-owned or user-editable; do not silently discard unknown keys until that contract is resolved.

Acceptance criteria:

- Blank required identity and invalid managed values fail before profile or repository mutation.
- Every accepted value is applied exactly, including supported non-boolean Git values.
- A malformed saved profile leaves all prior repository-local values unchanged.
- Older profiles missing newly defaulted fields remain supported.
- Focused schema tests and `bats tests/git-profile.bats` pass.

Completion evidence:

- Changed files: `tools/bin/git-profile`, `tests/git-profile.bats`, `README.md`, `docs/tasks/20260823-120246-git-profile-health-remediation.md`.
- Added schema-aware validation for required identity fields, Git boolean-compatible managed values, `core.autocrlf`, `pull.rebase`, `push.default`, and nonblank managed string fields.
- Validated create/update candidates before profile publication and validated saved profiles before `set` applies any repository-local config mutation.
- Documented saved profile files as tool-owned and reconstructed by `create`/`update`; unmanaged keys/comments are not preserved.
- Added regressions for blank identity rejection, invalid managed update values, accepted non-boolean Git enum values, malformed saved profile no-mutation behavior, and legacy profiles missing defaulted fields.
- `bash -n tools/bin/git-profile tests/git-profile.bats`: passed.
- `bats tests/git-profile.bats --filter 'blank required identity|invalid managed values|accepted non-boolean|malformed saved profile|missing defaulted managed fields|update context rewrites new managed options'`: 6 passed.
- `bats tests/git-profile.bats`: 63 passed.
- `shellcheck tools/bin/git-profile tests/git-profile.bats`: passed.
- `git diff --check`: passed.
- `pre-commit run --files tools/bin/git-profile tests/git-profile.bats README.md docs/tasks/20260823-120246-git-profile-health-remediation.md`: passed.
- Follow-up/blocker: none for SCHEMA-01.

### Task SSH-01: Persist A Structured SSH Key Path

Status: completed

Priority: P1

Suggested agent: Bash compatibility engineer

Dependencies: SCHEMA-01

Primary ownership:

- `tools/bin/git-profile`
- SSH create/read/commands/clone/delete tests in `tests/git-profile.bats`
- Help/README only if the persisted contract is documented

Finding:

`build_ssh_command` stores a `%q`-escaped shell command, while `extract_ssh_key_path` cannot reverse that representation and rejects remaining backslashes. A key path containing spaces works for clone because clone reuses the full command, but disappears from read, public-key display, `commands`, and delete. Parsed relative paths beginning with `-` can also become options to `ssh-add` or `rm`.

References:

- `tools/bin/git-profile:455-469`
- `tools/bin/git-profile:608-725`
- `tools/bin/git-profile:1041-1055`
- `tools/bin/git-profile:1097-1103`
- `tools/bin/git-profile:1424-1439`
- `tests/git-profile.bats:361-448`
- `tests/git-profile.bats:916-978`
- `tests/git-profile.bats:1054-1082`

Implementation requirements:

1. Add an explicit tool-owned SSH key-path field and derive the managed `core.sshCommand` from structured data rather than parsing arbitrary shell text.
2. Retain a deliberately narrow legacy parser for commands previously emitted by `build_ssh_command`; document unsupported hand-edited command forms.
3. Preserve spaces and shell-significant filename characters without evaluating profile content.
4. Require an absolute managed key path or use option terminators supported by the target commands; `rm` must use `--`.
5. Use the same resolved path for read, public-key display, shell commands, clone, and delete.

Acceptance criteria:

- New and legacy profiles with a key path containing spaces work consistently in create, read, `read --commands`, aggregate `commands`, clone, and delete.
- No profile text is passed through `eval` or reparsed as general shell syntax.
- Dash-leading paths cannot alter `ssh-add` or `rm` behavior.
- Existing simple-path profiles remain compatible.
- `bats tests/git-profile.bats` passes.

Completion evidence:

- Changed files: `tools/bin/git-profile`, `tests/git-profile.bats`, `docs/tasks/20260823-120246-git-profile-health-remediation.md`.
- New profiles now persist `picotools.sshKeyPath` as the managed structured SSH key path and derive `core.sshCommand` with `build_ssh_command` from that path.
- Existing legacy profiles remain supported only through the narrow command form emitted by `build_ssh_command`; no `eval` or arbitrary shell parsing was added.
- User-supplied SSH key paths are resolved to absolute paths before managed persistence; structured path reads validate absolute paths, `ssh-add` uses `--`, and SSH/PAT/profile deletion paths use `rm --` where relevant to SSH-01.
- Read, public-key display, `read --commands`, aggregate `commands`, clone, and delete now resolve through the same structured-or-legacy SSH key path helper.
- Added compatibility coverage for new structured and legacy profiles with spaces, dash-leading filenames, and shell-significant characters across read/public key display, commands, clone, and delete.
- `bash -n tools/bin/git-profile tests/git-profile.bats`: passed.
- `bats tests/git-profile.bats --filter 'structured SSH|legacy SSH|clone with SSH profile preserves spaces|create context with existing SSH|read context displays detailed values|read context can display public SSH key|read commands prints ssh-add|commands prints ssh-add'`: 8 passed.
- `bats tests/git-profile.bats`: 65 passed.
- `shellcheck tools/bin/git-profile tests/git-profile.bats`: passed.
- `git diff --check`: passed.

### Task CORRECT-01: Close Remaining Error And Argument Boundaries

Status: completed

Priority: P1

Suggested agent: Bash correctness engineer

Dependencies: SCHEMA-01, STATE-02

Primary ownership:

- `tools/bin/git-profile`
- Focused CLI/GPG/selection/clone tests in `tests/git-profile.bats`

Finding:

Several independent boundaries fail open or produce misleading results: `token` and most other subcommands ignore extra arguments; a successful GPG command without `KEY_CREATED` expands an uninitialized variable under `set -u`; selection failures are converted to success; and clone does not terminate Git option parsing before the URL.

References:

- `tools/bin/git-profile:775-821`
- `tools/bin/git-profile:991-1017`
- `tools/bin/git-profile:1057-1069`
- `tools/bin/git-profile:1120-1127`
- `tools/bin/git-profile:1181-1198`
- `tools/bin/git-profile:1338-1452`
- `tools/bin/git-profile:1468-1545`

Implementation requirements:

1. Define and enforce command arity; `token` and all no-argument commands must reject extras before performing work or printing a secret.
2. Document whether `--debug` is global-only or accepted after subcommands and test the selected grammar consistently.
3. Initialize GPG parse state and return the intended diagnostic when status output lacks one valid `KEY_CREATED` record.
4. Define exit statuses for no profiles, invalid selection, and explicit cancellation; propagate failure instead of returning success unless no-op success is deliberately documented.
5. Add `--` before user-controlled clone URL operands and capture stub arguments individually in tests.

Acceptance criteria:

- `git-profile token --help unexpected` fails without printing a PAT.
- Every command rejects unsupported arguments with nonzero status and actionable usage.
- Missing/malformed GPG status produces the intended error, not an unbound-variable diagnostic.
- Selection/cancellation status matches the documented policy.
- A dash-leading clone operand is treated as an operand or rejected by explicit validation, never as a Git option.
- `bats tests/git-profile.bats` passes.

Completion evidence:

- Changed files: `tools/bin/git-profile`, `tests/git-profile.bats`, `docs/tasks/20260823-120246-git-profile-health-remediation.md`.
- Documented `--debug` as global-only in help and reject subcommand-local `--debug` consistently for `clone`.
- Added dispatch-level arity checks for no-argument commands before command work, including `token` before repository/PAT reads.
- Initialized and validated GPG `KEY_CREATED` parse state, requiring exactly one valid generated-key status record with a stable diagnostic for missing/malformed output.
- Made profile selection failures return nonzero for no profiles, invalid selections, and explicit cancellation; cancellation reports `Cancelled.`.
- Added `--` before clone URL operands and regression coverage that captures stubbed `git` arguments one per line for a dash-leading URL.
- Added focused regressions for token extra arguments without secret printing, unsupported no-argument command args, global-only debug grammar, GPG missing/malformed status, selection failure/cancellation status, and clone operand boundary.
- `bash -n tools/bin/git-profile tests/git-profile.bats`: passed.
- `bats tests/git-profile.bats --filter 'no-argument commands reject|debug is accepted|token rejects extra|GPG KEY_CREATED|profile selection failures|clone separates dash-leading'`: 7 passed.
- `bats tests/git-profile.bats`: 72 passed.
- `shellcheck tools/bin/git-profile tests/git-profile.bats`: passed.
- `git diff --check`: passed.
- `pre-commit run --files tools/bin/git-profile tests/git-profile.bats docs/tasks/20260823-120246-git-profile-health-remediation.md`: passed.
- Follow-up/blocker: none for CORRECT-01.

### Task PROMPT-01: Stop Required Secret Prompts On EOF

Status: completed

Priority: P1

Suggested agent: shared prompt-helper maintainer

Dependencies: none

Primary ownership:

- `lib/picotools/prompt.sh`
- Shared prompt tests or the smallest relevant consumer tests
- `tests/git-profile.bats` only for one integration regression

Finding:

`picotools_prompt_secret_value` turns a failed read into an empty answer and loops forever when the value is required. `git-profile update` uses that required path for PAT add/replace, so closed stdin can hang automation indefinitely.

References:

- `lib/picotools/prompt.sh:150-186`
- `tools/bin/git-profile:1278-1287`
- `tests/git-profile.bats:1394-1426`

Implementation requirements:

1. Preserve the underlying read status and return nonzero on EOF instead of retrying forever.
2. Keep interactive empty-input retry behavior for a connected input stream.
3. Audit all callers of `picotools_prompt_secret_value` and update tests for any contract-sensitive consumer.
4. Add a timeout-bounded `git-profile update` regression proving closed stdin exits promptly and leaves profile/token state unchanged.

Acceptance criteria:

- Required secret input on EOF returns nonzero promptly with a non-secret diagnostic.
- Interactive retries and optional blank secret prompts retain their existing behavior.
- Relevant shared-helper/consumer tests and `bats tests/git-profile.bats` pass.

Completion evidence:

- Changed files: `lib/picotools/prompt.sh`, `tests/prompt.bats`, `tests/git-profile.bats`, `docs/tasks/20260823-120246-git-profile-health-remediation.md`.
- `picotools_prompt_secret_value` now preserves secret-read status, fails required empty EOF with `Error: input ended before required value was provided.`, and keeps empty interactive retries plus optional blank secret prompts.
- Audited callers in `tools/bin/git-profile`, `tools/bin/model-profile`, `tools/bin/git-api`, and `tools/bin/git-release-setup`; no consumer code changes were needed because required call sites already abort on nonzero helper status and optional call sites still accept blank input.
- Added shared prompt regressions for required interactive retry, required EOF failure, and optional EOF-as-blank behavior.
- Added timeout-bounded `git-profile update` regression proving closed stdin exits before timeout and preserves the prior profile/token.
- `bash -n lib/picotools/prompt.sh tools/bin/git-profile tools/bin/model-profile tools/bin/git-api tools/bin/git-release-setup tests/prompt.bats tests/git-profile.bats tests/model-profile.bats`: passed.
- `bats tests/prompt.bats`: 10 passed.
- `bats tests/git-profile.bats --filter 'update PAT prompt fails promptly on EOF'`: 1 passed.
- `bats tests/git-profile.bats`: 73 passed.
- `bats tests/model-profile.bats`: 18 passed.
- `bats tests/git-release-setup.bats`: 12 passed.
- `bats tests/git-api.bats`: 23 passed with 300000 ms tool timeout after the first 120000 ms tool timeout terminated after 13 passing tests.
- `shellcheck lib/picotools/prompt.sh tools/bin/git-profile tests/prompt.bats tests/git-profile.bats`: passed.
- `git diff --check`: passed.
- `pre-commit run --files lib/picotools/prompt.sh tests/prompt.bats tests/git-profile.bats docs/tasks/20260823-120246-git-profile-health-remediation.md`: passed.
- Follow-up/blocker: none for PROMPT-01.

## Wave 3: Architecture, Readability, And Performance

### Task ARCH-01: Extract Cohesive Git Profile Modules

Status: completed

Priority: P2

Suggested agent: Bash architecture engineer

Dependencies: SEC-01, STATE-01, STATE-02, SCHEMA-01, SSH-01, CORRECT-01

Primary ownership:

- `tools/bin/git-profile`
- New files under `tools/lib/picotools/git-profile/`
- Matching tests and installed-layout smoke coverage

Finding:

The executable combines unrelated domains, while core functions carry 12 or 16 positional parameters and pass-through wrappers add indirection without owning behavior. This makes lifecycle invariants difficult to audit and forces most tests through interactive whole-command flows.

References:

- `tools/bin/git-profile:276-409`
- `tools/bin/git-profile:455-890`
- `tools/bin/git-profile:892-1548`
- `tests/git-profile.bats:1-226`

Implementation requirements:

1. Keep dispatch and user-flow orchestration in the executable; extract only stable profile schema/storage, PAT storage, and SSH/GPG resource functions with explicit interfaces.
2. Replace high-arity positional profile state with a scoped associative array or another auditable Bash representation; avoid global mutable state except registered cleanup resources.
3. Remove pure pass-through wrappers unless the extracted boundary gives them schema or policy ownership.
4. Make modules safe for repeated sourcing and resolve them in both repository and installed layouts.
5. Add direct tests for pure validation/serialization functions while retaining end-to-end Bats coverage.
6. Do not move generic helpers into `lib/picotools` unless at least one sibling tool adopts and tests the same contract.

Acceptance criteria:

- The executable has clear orchestration boundaries and no 12/16-argument profile functions.
- Storage and schema invariants can be tested without running an interactive command.
- Repository and installed layouts both resolve the new modules.
- Behavior and public output remain unchanged except for contracts explicitly changed by earlier tasks.
- `bats tests/git-profile.bats`, installed-layout smoke tests, syntax checks, and pre-commit pass.

Completion evidence:

- Changed files for ARCH-01: `tools/bin/git-profile`, `tools/lib/picotools/git-profile/profile.sh`, `tools/lib/picotools/git-profile/token.sh`, `tools/lib/picotools/git-profile/resources.sh`, `tests/git-profile.bats`, `docs/tasks/20260823-120246-git-profile-health-remediation.md`.
- Extracted tool-specific modules for profile schema/storage, PAT storage, and SSH/GPG resource helpers under `tools/lib/picotools/git-profile/`, with idempotent load guards.
- Added repository and installed layout module resolution in `tools/bin/git-profile` while keeping dispatch and interactive user-flow orchestration in the executable.
- Replaced create/update/save profile persistence calls that previously passed 16 profile-state arguments with a scoped associative-array profile state, and removed pure pass-through table/display wrappers.
- Added direct module tests for candidate validation and profile serialization/validation, plus installed-layout operational `list` smoke coverage.
- `bash -n tools/bin/git-profile tools/lib/picotools/git-profile/profile.sh tools/lib/picotools/git-profile/token.sh tools/lib/picotools/git-profile/resources.sh tests/git-profile.bats`: passed.
- `bats tests/git-profile.bats`: 76 passed.
- `bats tests/git-profile.bats --filter 'profile modules|installed layout'`: 3 passed.
- Manual installed-layout smoke and syntax check using a temporary `bin/` plus `lib/picotools/git-profile/` layout: passed; output was `No git profiles found.`.
- `shellcheck tools/bin/git-profile tools/lib/picotools/git-profile/profile.sh tools/lib/picotools/git-profile/token.sh tools/lib/picotools/git-profile/resources.sh tests/git-profile.bats`: passed.
- `pre-commit run --files tools/bin/git-profile tools/lib/picotools/git-profile/profile.sh tools/lib/picotools/git-profile/token.sh tools/lib/picotools/git-profile/resources.sh tests/git-profile.bats docs/tasks/20260823-120246-git-profile-health-remediation.md`: passed.
- `git diff --check`: passed.
- Follow-up/blocker: none for ARCH-01.

### Task DEPS-01: Align Dependencies With Repository Conventions

Status: completed

Priority: P2

Suggested agent: picotools conventions maintainer

Dependencies: CORRECT-01, ARCH-01

Primary ownership:

- `tools/bin/git-profile`
- `README.md`
- Tests for missing dependencies
- `lib/picotools/git.sh` only if a shared contract change is approved

Finding:

The script directly invokes `git`, `gpg`, and `ssh-keygen`, sources neither `commands` nor `git`, and reimplements repository detection. This conflicts with local conventions and delays missing-command errors. The README does not distinguish mandatory `git` from conditional GPG/SSH dependencies.

References:

- `tools/bin/git-profile:12`
- `tools/bin/git-profile:727-821`
- `tools/bin/git-profile:1129-1136`
- `lib/picotools/commands.sh:8-31`
- `lib/picotools/git.sh:8-21`
- `README.md:43`

Implementation requirements:

1. Source directly used `commands` and `git` modules explicitly.
2. Check `git` before operational commands and check `ssh-keygen`/configured GPG command only when those flows need them.
3. Preserve command-specific repository diagnostics required by `set` and `token`; avoid broad shared-helper changes if a local wrapper suffices.
4. If `lib/picotools/git.sh` changes, add sibling-tool regression coverage and serialize that shared-file edit.
5. Document mandatory and conditional dependencies.

Acceptance criteria:

- Missing tools fail before prompting or mutation with helper-consistent diagnostics.
- Help/version remain usable without optional operational dependencies.
- `set` and `token` retain precise repository errors or all consumers/tests are updated together.
- Focused tests and pre-commit pass.

Completion evidence:

- Changed files for DEPS-01: `tools/bin/git-profile`, `tools/lib/picotools/git-profile/resources.sh`, `tests/git-profile.bats`, `README.md`, `docs/tasks/20260823-120246-git-profile-health-remediation.md`.
- `git-profile` now explicitly sources `commands` and `git`, requires `git` for operational commands, and keeps `set`/`token` repository diagnostics unchanged when `git` is available outside a repository.
- Generated SSH key creation now requires `ssh-keygen` only when generation is requested; generated GPG signing keys and confirmed GPG key deletion require the configured GPG command only in those flows, with delete preflight before profile/PAT mutation.
- README and help text document mandatory `git` and conditional `ssh-keygen`/GPG dependencies.
- Added regressions for help/version without operational dependencies, missing `git` before create prompts/saves, missing `ssh-keygen` before later generated-SSH prompts/saves, missing `gpg` before PAT prompt/save, and missing configured GPG before delete mutation.
- `bash -n tools/bin/git-profile tools/lib/picotools/git-profile/profile.sh tools/lib/picotools/git-profile/resources.sh tools/lib/picotools/git-profile/token.sh tests/git-profile.bats`: passed.
- `git diff --check`: passed.
- `bats tests/git-profile.bats --filter 'operational dependencies|requires git|requires ssh-keygen|requires gpg|configured GPG command'`: 5 passed.
- `bats tests/git-profile.bats --filter 'set fails outside git repository|token fails outside a git repository|token fails when the repository marker is missing'`: 3 passed.
- `shellcheck tools/bin/git-profile tools/lib/picotools/git-profile/profile.sh tools/lib/picotools/git-profile/resources.sh tools/lib/picotools/git-profile/token.sh tests/git-profile.bats`: passed.
- `bats tests/git-profile.bats`: 81 passed.
- `pre-commit run --files tools/bin/git-profile tools/lib/picotools/git-profile/resources.sh tests/git-profile.bats README.md docs/tasks/20260823-120246-git-profile-health-remediation.md`: passed.
- Follow-up/blocker: none for DEPS-01.

### Task PERF-01: Measure And Reduce Profile I/O Churn

Status: deferred

Priority: P3

Suggested agent: Bash performance engineer

Dependencies: ARCH-01

Primary ownership:

- Benchmark/profiling fixture
- Extracted profile read/write module
- `tools/bin/git-profile` only for proven changes

Finding:

List, read, update, save, and apply launch one `git config` process per field, plus per-profile utilities such as `basename` and token normalization. This is unlikely to matter for a few profiles, so optimization is not justified without a representative measurement.

References:

- `tools/bin/git-profile:470-499`
- `tools/bin/git-profile:505-586`
- `tools/bin/git-profile:844-890`
- `tools/bin/git-profile:972-989`
- `tools/bin/git-profile:1138-1179`
- `tools/bin/git-profile:1212-1239`

Implementation requirements:

1. Add a reproducible benchmark for list/read/update with representative sets such as 1, 25, and 100 profiles.
2. Record subprocess count and wall-clock baseline before changing behavior.
3. If measurements justify work, parse one `git config --null --list` result per profile and reuse validated in-memory state; preserve duplicate-key semantics explicitly.
4. Do not optimize shared table helpers unless separate profiling identifies them as material.
5. If no meaningful gain is demonstrated, mark this task deferred with evidence rather than adding complexity.

Acceptance criteria:

- Baseline and after measurements are recorded with environment and commands.
- Any optimization preserves malformed/duplicate config handling and all output contracts.
- A retained implementation change produces a material documented improvement without reducing test coverage.
- Otherwise the task is `deferred` with benchmark evidence and no production-code churn.

Completion evidence:

- Changed files for PERF-01: `scripts/benchmark-git-profile-io.bash`, `docs/tasks/20260823-120246-git-profile-health-remediation.md`.
- Added reproducible benchmark fixture: `scripts/benchmark-git-profile-io.bash --counts "1 25 100" --repeat 5`.
- Benchmark environment: Linux 5CG5181VVF-N 6.18.33.2-microsoft-standard-WSL2 x86_64; Bash 5.2.21(1)-release; Git 2.43.0; tool `/home/jahn/projects/_picotools/tools/bin/git-profile`; isolated temporary `HOME`, `XDG_CONFIG_HOME`, and `XDG_DATA_HOME` generated by the fixture.
- Retained-code benchmark results from `scripts/benchmark-git-profile-io.bash --counts "1 25 100" --repeat 5`: 1 profile: list 10 subprocesses/0.208526s, read 23/0.589532s, update 56/0.059824s; 25 profiles: list 190/2.675859s, read 47/0.771087s, update 80/0.507728s; 100 profiles: list 753/10.408820s, read 122/0.976614s, update 155/0.616672s.
- Earlier same-command baseline before an attempted local cache experiment was: 1 profile: list 10/0.415077s, read 23/0.634223s, update 56/0.454732s; 25 profiles: list 190/2.116934s, read 47/0.620254s, update 80/0.370148s; 100 profiles: list 753/9.674047s, read 122/0.358379s, update 155/0.617279s.
- A local prototype that parsed `git config --null --list` once per profile reduced subprocess counts for some paths but did not produce a material wall-clock improvement and regressed some scenarios, so it was not retained. Prototype result: 100 profiles list 453 subprocesses/9.491391s, read 6/1.051910s, update 73/1.117465s.
- No production profile I/O optimization was retained; shared table helpers were not changed.
- Residual risk: `list` remains subprocess-heavy for large profile sets, but avoiding a cache preserves simple `git config` semantics and avoids complexity until a better measured design shows clear wall-clock improvement.

### Task TEST-01: Organize Tests Around Stable Domains

Status: completed

Priority: P2

Suggested agent: Bats test architecture engineer

Dependencies: ARCH-01

Primary ownership:

- `tests/git-profile.bats`
- New focused Bats helper/test files if warranted
- Test invocation metadata such as `package.json`

Finding:

The 1,632-line Bats file mixes approximately 225 lines of assertions/fixtures with storage, key lifecycle, repository, clone, prompt, and CLI scenarios. Repeated ad hoc command stubs flatten arguments through `$*`, which hides argument-boundary defects.

References:

- `tests/git-profile.bats:1-226`
- `tests/git-profile.bats:285-615`
- `tests/git-profile.bats:767-1322`
- `tests/git-profile.bats:1324-1632`
- `package.json:15-20`

Implementation requirements:

1. Extract reusable fixtures/assertions first; split files only along stable storage, key-material, repository, and CLI boundaries.
2. Capture subprocess arguments one per line or with a lossless delimiter instead of `$*` where argument boundaries matter.
3. Keep each test isolated under its Bats temporary home and ensure secret fixtures are removed by teardown.
4. Update `test:git-profile` so every split file runs; retain `bats tests/*.bats` compatibility.
5. Do not duplicate end-to-end cases already covered by direct module tests unless they protect a public contract.

Acceptance criteria:

- One command runs the complete `git-profile` suite after any split.
- Security-sensitive argument tests distinguish one argument from multiple flattened words.
- No test ordering dependency or persistent secret artifact exists.
- Test count and behavior coverage do not regress.

Completion evidence:

- Changed files for TEST-01: `tests/git-profile.bats`, `tests/helpers/git-profile.bash`, `package.json`, `docs/tasks/20260823-120246-git-profile-health-remediation.md`.
- Extracted reusable git-profile Bats setup, teardown, fixtures, module sourcing, and assertions into `tests/helpers/git-profile.bash`; retained the scenario file as a smaller complete organization step because a full 81-test split would add risky churn while concurrent baseline work is present.
- Kept every git-profile test isolated under a Bats-created temporary home with `HOME`, `XDG_CONFIG_HOME`, and `XDG_DATA_HOME` set per test and removed by teardown, covering secret PAT fixtures under the temporary tree.
- Updated git-profile subprocess stubs that asserted security-sensitive argument boundaries to record arguments one per line instead of flattened `$*`, and adjusted clone/SSH-key assertions to preserve one-argument versus multiple-word distinctions.
- Updated `test:git-profile` to `bats tests/git-profile*.bats` so any focused git-profile split files run from one command while existing `bats tests/*.bats` compatibility is retained.
- `bash -n tests/helpers/git-profile.bash`: passed.
- `npm run test:git-profile`: 81 passed.
- `bats tests/*.bats`: 339 passed.
- `shellcheck tests/git-profile.bats tests/helpers/git-profile.bash`: passed.
- `git diff --check`: passed.
- Follow-up/blocker: none for TEST-01.

## Wave 4: Documentation, CI, And Independent Review

### Task DOC-CI-01: Align Public Contracts And Installed Checks

Status: completed

Priority: P2

Suggested agent: documentation and CI engineer

Dependencies: DEPS-01, TEST-01

Primary ownership:

- `README.md`
- `usage()` in `tools/bin/git-profile`
- `.github/workflows/test.yml`
- `.github/workflows/pre-commit.yml`

Finding:

The README compresses the complete `git-profile` contract into one paragraph. Test CI ignores Markdown-only changes, pre-commit runs only on push, and installed-layout coverage exercises only help/version rather than an operational profile path.

References:

- `README.md:43`
- `.github/workflows/test.yml:3-9`
- `.github/workflows/test.yml:33-79`
- `.github/workflows/pre-commit.yml:1-3`

Implementation requirements:

1. Document dependencies, permission/read policy, command grammar, failure-safe persistence guarantees, and structured SSH compatibility established by prior tasks.
2. Keep the token stdout warning and repository PAT precedence aligned with `git-commit` and `git-api` documentation.
3. Ensure Markdown-only pull requests receive an appropriate lightweight check.
4. Add an installed-layout operation using isolated temporary XDG directories, such as empty `list` plus a non-secret create/read path.
5. Keep PAT fixtures out of workflow YAML and logs.

Acceptance criteria:

- Help, README, implementation, and tests describe the same behavior.
- A Markdown-only pull request triggers at least one relevant validation workflow.
- Installed-layout CI executes `git-profile` beyond help/version without touching runner user state.
- Workflow syntax and focused pre-commit checks pass.

Completion evidence:

- Changed files for DOC-CI-01: `README.md`, `tools/bin/git-profile`, `tests/git-profile.bats`, `.github/workflows/test.yml`, `.github/workflows/pre-commit.yml`, `docs/tasks/20260823-120246-git-profile-health-remediation.md`.
- README and help now document `git-profile` dependencies, global-only `--debug` grammar, command-specific arguments, fail-closed PAT read/status permission policy, atomic PAT/profile persistence behavior, structured `picotools.sshKeyPath` with narrow legacy SSH command compatibility, token stdout warning, and repository PAT precedence through existing `git-commit`/`git-api` documentation.
- The `pre-commit` workflow now runs on Markdown pull requests, giving Markdown-only PRs a lightweight validation path while preserving push validation.
- Installed-layout CI now runs isolated `git-profile` operations beyond help/version: empty `list`, non-secret `create`, and `read`, using temporary `HOME`, `XDG_CONFIG_HOME`, and `XDG_DATA_HOME` and no PAT fixtures in workflow YAML or logs.
- Added/updated focused help-output assertions in `tests/git-profile.bats` for the documented command grammar and public contracts.
- `bash -n tools/bin/git-profile tests/git-profile.bats tests/helpers/git-profile.bash`: passed.
- `pre-commit run check-yaml --files .github/workflows/test.yml .github/workflows/pre-commit.yml`: passed.
- Local installed-layout smoke matching the new CI `git-profile` list/create/read path with isolated XDG directories: passed.
- `npm run test:git-profile`: 81 passed.
- `pre-commit run --files README.md tools/bin/git-profile tests/git-profile.bats .github/workflows/test.yml .github/workflows/pre-commit.yml docs/tasks/20260823-120246-git-profile-health-remediation.md`: passed.
- `git diff --check`: passed.
- Follow-up/blocker: none for DOC-CI-01.

### Task REVIEW-01: Perform Independent Security And Integration Review

Status: completed

Priority: P0

Suggested agent: independent Bash/security reviewer not used for implementation

Dependencies: SEC-01, STATE-01, STATE-02, SCHEMA-01, SSH-01, CORRECT-01, PROMPT-01, ARCH-01, DEPS-01, TEST-01, DOC-CI-01; PERF-01 may be completed or explicitly deferred

Primary ownership:

- Review only, plus focused fixes/tests for discovered regressions

Finding:

The remediation crosses secret paths, persistent schema, destructive key operations, repository-local config, shared prompts, installed packaging, and a token contract consumed by `git-commit`. An independent pass must validate runtime behavior and failure paths rather than implementation shape alone.

References:

- All tasks and acceptance criteria in this document
- `tools/bin/git-commit:1395-1421`
- `docs/tasks/20260818-212431-repository-git-profile-pat-auth.md`

Implementation requirements:

1. Reproduce parent-symlink, hard-link, non-regular-file, permissive-mode, multiline-token, and failure-injection cases against the final implementation.
2. Verify failed create/update/delete/set operations preserve the state promised by their contracts.
3. Verify new and legacy SSH profiles across read, commands, clone, and delete, including spaces and option-like paths.
4. Verify no PAT crosses config, argv, logs, errors, tables, test output, or retained temporary artifacts.
5. Verify `git-commit` still recognizes expected no-marker/no-PAT fallback behavior.
6. Review module ownership, installed layout, test command coverage, and every deferred item with residual risk.
7. Preserve unrelated worktree changes and report exact pre-existing failures rather than masking them.

Acceptance criteria:

- Every prior task has runtime or test evidence for each acceptance criterion.
- `bats tests/git-profile*.bats tests/git-commit.bats` passes, adjusted to the final test filenames.
- `bats tests/*.bats` passes.
- `bash -n bin/* tools/bin/* scripts/*.bash` passes.
- `scripts/shfmt-diff.bash` reports no diff.
- `pre-commit run --all-files` passes, or unrelated pre-existing failures are recorded exactly.
- The installed archive passes its operational `git-profile` smoke test.
- No secret-bearing or transaction temporary artifacts remain in the worktree.

Completion evidence:

- Independent review found no focused regressions requiring code changes.
- Reviewed task status/evidence for all prior tasks, final `tools/bin/git-profile`, extracted `tools/lib/picotools/git-profile/` modules, shared prompt helper, `tests/git-profile.bats`, `tests/git-commit.bats`, README/help text, workflow installed-layout changes, and `tools/bin/git-commit` repository-PAT fallback handling.
- Verified runtime/test coverage for symlinked PAT data directories, symlink token leaves, hard-link replacement, FIFO rejection, permission and multiline token fail-closed behavior, create/update/delete/set failure preservation, structured and legacy SSH paths, no PAT leakage through config/argv/output/debug, `git-commit` fallback behavior, module ownership, installed layout, and the deferred PERF-01 residual risk.
- `bats tests/git-profile*.bats tests/git-commit.bats`: 149 passed.
- `bats tests/*.bats`: 339 passed.
- `bash -n bin/* tools/bin/* scripts/*.bash`: passed.
- `scripts/shfmt-diff.bash`: passed with no diff.
- `pre-commit run --all-files`: passed.
- Installed archive operational `git-profile` smoke using isolated `/tmp/opencode` install/home/XDG paths: passed for help/version, empty `list`, non-secret `create`, and `read`.
- Workspace artifact check found no `*.token`, `.*.token.tmp.*`, `.*.gitconfig.tmp.*`, `*.gitconfig.backup.*`, `.gitconfig`, or `.git/config.lock` files under the repository.
- Follow-up/blocker: none for REVIEW-01.

## Dependencies And Parallelization

| Wave | Task | May run in parallel with | Must not overlap |
|---|---|---|---|
| 1 | SEC-01 | PROMPT-01 | STATE-01, STATE-02 or any edit to core PAT tests |
| 1 | STATE-01 | None on core files | Any task editing `git-profile` or its Bats file |
| 1 | STATE-02 | PROMPT-01 after SEC-01 | Any task editing delete paths/tests |
| 2 | SCHEMA-01 | PROMPT-01 | SSH-01, CORRECT-01 |
| 2 | SSH-01 | PROMPT-01 | Any task editing core script/tests |
| 2 | CORRECT-01 | PROMPT-01 | Any task editing dispatcher/core tests |
| 3 | ARCH-01 | CI investigation only | Core behavior tasks |
| 3 | DEPS-01 | PERF-01 benchmark collection | Shared core/module edits |
| 3 | PERF-01 | TEST-01 only if file ownership is separated | Extracted profile read/write module edits |
| 3 | TEST-01 | Documentation drafting | Shared test helpers/files |
| 4 | DOC-CI-01 | None after contracts finalize | README edits documenting `git-commit`/`git-api` |
| 4 | REVIEW-01 | None | All implementation work |

Shared hotspots are `tools/bin/git-profile`, `tests/git-profile.bats`, and `README.md`. Agents must re-read these files immediately before editing. Repository-wide formatting and full pre-commit must not run concurrently with active editors because formatting commands may write files.

## Deferred Decisions Requiring Maintainer Input

1. PAT permission drift: choose fail-closed reads for a non-`0700` data directory or non-`0600` token file, or repair safe same-owner paths on access. Recommended: fail closed on reads and repair only during explicit writes; this avoids surprising mutation and makes the documented protection enforceable.
2. Generated credential rollback: choose whether failed create automatically deletes SSH/GPG material generated by that invocation or retains it with a precise recovery message. Recommended: roll back generated SSH files; retain generated GPG keys only if reliable scoped deletion cannot be guaranteed, and report the fingerprint.
3. Profile-file ownership: decide whether users may add unmanaged keys/comments to saved `.gitconfig` files. If supported, update must preserve them; if unsupported, document files as tool-owned before keeping reconstruction semantics.
4. SSH schema key: approve a tool-owned key such as `picotools.sshKeyPath` for new profiles and the duration of legacy `core.sshCommand` parsing support.

SEC-01 can begin with path and atomic-write regressions before decision 1. STATE-01 can begin with rollback regressions before decisions 2 and 3. SSH-01 is blocked on decision 4 after its failing compatibility tests are written.

## Definition Of Done

- PAT operations cannot escape through a symlinked parent, hard link, or non-regular destination, and malformed/insecure token files follow an explicit policy.
- Create, update, delete, and set have tested failure semantics that do not leave silent partial state.
- Managed profile values are validated as a complete schema before persistence or repository mutation.
- SSH key paths are stored structurally and remain compatible with existing generated profiles.
- Command arity, option boundaries, GPG status parsing, selection status, and secret-prompt EOF behavior are explicit and tested.
- The executable is decomposed only after behavior stabilizes, with reusable tool-specific modules and direct tests.
- Performance work is evidence-based and may be deferred without production churn.
- Dependencies, README/help contracts, workflows, installed layout, and runtime behavior agree.
- Targeted and full verification pass, and the independent reviewer records completion evidence in this file.
