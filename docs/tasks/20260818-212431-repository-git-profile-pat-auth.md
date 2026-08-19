# Repository-Aware Git Profile PAT Authentication

Created: 2026-08-18 21:24:31 -0700

## Objective

Make the active `git-profile` an explicit property of each local Git repository, let a git profile optionally own a securely stored GitHub personal access token (PAT), and make `git-commit --pr` prefer that repository-specific PAT for every `git-api` call.

The completed authentication precedence must be:

1. PAT belonging to the `git-profile` recorded in the current repository.
2. `git-api.profile` selected by `git-commit configure`.
3. Existing `git-api` authentication resolution, unchanged: its selected named profile, supported token environment variables, or legacy token file.

## Architectural Decisions

- Store the active profile name, never the PAT, in repository-local Git config as `picotools.gitProfile`.
- Keep profile metadata at `${XDG_CONFIG_HOME:-$HOME/.config}/git-profile/<name>.gitconfig` as today.
- Store each optional PAT separately at `${XDG_DATA_HOME:-$HOME/.local/share}/git-profile/<name>.token`.
- Follow the repository's `model-profile` and `git-api` convention: token files are plaintext user data protected by a `0700` directory and `0600` file mode. This protects against other local users but is not encryption or an OS keyring.
- Add `git-profile token` as the narrow repository-context lookup command. It must resolve `picotools.gitProfile`, validate that the named profile still exists, and print only that profile's token to stdout.
- `git-profile list`, `read`, summaries, and debug output may show only whether a PAT is configured. They must never render the token value or token-bearing command lines.
- Preserve `git-api --token TOKEN`; it already provides the dynamic one-call token override requested by the original requirements (`tools/bin/git-api:37-39`, `tools/bin/git-api:416-423`). Do not add a second positional PAT contract.
- Add `git-api --token-stdin` for picotool-to-picotool secret handoff so `git-commit` does not place a repository PAT in process arguments. It has the same highest authentication precedence as `--token`, reads one token from stdin, and is mutually exclusive with `--token`.
- Resolve the repository PAT once per `git-commit --pr` run and use the same resolved authentication for default-branch lookup, existing-PR lookup, and PR creation or update.
- A missing local profile marker or missing PAT is an expected fallback condition. A stored PAT must take precedence over `git-commit`'s configured `git-api.profile`.

## Scope

- `tools/bin/git-profile`
- `tools/bin/git-api`
- `tools/bin/git-api.d/common.sh` only if token resolution needs a shared helper adjustment
- `tools/bin/git-commit`
- `tests/git-profile.bats`
- `tests/git-api.bats`
- `tests/git-commit.bats`
- `README.md`

## Non-Goals

- Migrating existing `git-api` named profiles or legacy PAT files into `git-profile`.
- Sharing one secret file between `git-profile` and `git-api`; they remain separate owners with separate lifecycle rules.
- Encrypting PAT files or integrating an OS credential manager.
- Automatically inferring a git profile from `user.name`, `user.email`, SSH keys, remotes, or a `git-api` profile name.
- Changing standalone `git-api` authentication precedence except for the explicit `--token-stdin` override.
- Removing the existing optional `git-api.profile` setting from `git-commit`; it remains the fallback.

## Confirmed Baseline

- `git-profile set` copies managed profile values into local Git config but does not record the selected profile name (`tools/bin/git-profile:950-1008`).
- `git-profile clone` applies the SSH key only for the clone process and does not persist the selected profile in the cloned repository (`tools/bin/git-profile:1195-1214`).
- Git profile files currently live under `XDG_CONFIG_HOME` and contain non-secret Git settings (`tools/bin/git-profile:91-110`, `tools/bin/git-profile:670-716`).
- `model-profile` separates config and token storage between `XDG_CONFIG_HOME` and `XDG_DATA_HOME`, and writes token files under `umask 077` (`tools/bin/model-profile:119-130`, `tools/bin/model-profile:219-227`, `tools/bin/model-profile:587-600`).
- `git-api` stores tokens below `${XDG_DATA_HOME:-$HOME/.local/share}/git-api` and writes them under `umask 077` (`tools/bin/git-api.d/common.sh:11-24`, `tools/bin/git-api.d/common.sh:63-83`).
- `git-api --token TOKEN` already sets the highest-priority `GIT_API_TOKEN_OVERRIDE` (`tools/bin/git-api:416-423`, `tools/bin/git-api.d/common.sh:257-264`).
- `git-commit` currently discovers named `git-api` profiles directly from `~/.local/share/git-api/profiles`, saves one optional profile globally, and forwards only `--profile` (`tools/bin/git-commit:95-109`, `tools/bin/git-commit:141-161`, `tools/bin/git-commit:259-281`).
- `git-commit` loads the optional `git-api.profile` before all PR-related calls (`tools/bin/git-commit:1800-1849`).
- Existing coverage verifies the configured fallback profile is passed to both default-branch and PR calls (`tests/git-commit.bats:2077-2107`).
- The repository's Bash conventions require matching Bats coverage, `bash -n`, all Bats tests, shellcheck/pre-commit, and two-space shfmt formatting (`.opencode/skills/bash-tool-conventions/SKILL.md:132-143`).

## Baseline Verification

Run on 2026-08-18 before creating this task:

- `bats tests/git-profile.bats`: 27 passed.
- `bats tests/git-api.bats`: 19 passed.
- `bats tests/git-commit.bats`: 64 passed.
- `bash -n tools/bin/git-profile tools/bin/git-api tools/bin/git-commit tools/bin/git-api.d/common.sh tools/bin/git-api.d/http.sh tools/bin/git-api.d/spec.sh`: passed.

The worktree already contained unrelated changes in `README.md`, `tests/git-release-setup.bats`, and `tools/bin/git-release-setup`. Implementers must preserve and work around those changes rather than reverting them.

## Priorities

- P0: Secret isolation, non-disclosure, file permissions, and correct auth precedence.
- P1: Repository profile identity, profile lifecycle, fallback behavior, and regression coverage.
- P2: Documentation and final integration checks.

## Wave 1: Git Profile Context And Secret Lifecycle

### Task PROFILE-01: Persist The Active Profile In Local Git Config

Status: completed

Priority: P1

Suggested agent: Bash CLI engineer

Dependencies: none

Primary ownership:

- `tools/bin/git-profile`
- `tests/git-profile.bats`

Finding:

`set_context_file` applies profile values but does not leave a stable profile identity, so another tool cannot determine which saved profile owns the current repository. The clone path similarly uses only transient SSH state.

References:

- `tools/bin/git-profile:307-319`
- `tools/bin/git-profile:950-1008`
- `tools/bin/git-profile:1195-1214`
- `tests/git-profile.bats:747-894`
- `tests/git-profile.bats:988-1072`

Implementation requirements:

1. Define `picotools.gitProfile` as the single repository-local identity key.
2. When `git-profile set` succeeds, replace all existing values for that key with the selected profile name, using the existing duplicate-safe local-config helper.
3. Make `git-profile clone <profile> <url>` persist the same key in the new repository as part of clone creation, preferably with Git's `clone --config key=value` facility so no destination-path inference is required.
4. Preserve existing SSH behavior and profile-name validation.
5. Do not put `picotools.gitProfile` into the saved profile `.gitconfig`; the filename remains the saved profile's identity.

Acceptance criteria:

- After `git-profile set`, `git config --local --get-all picotools.gitProfile` returns exactly the selected profile name.
- Selecting another profile replaces, rather than appends to, stale or duplicate local marker values.
- A clone made with an SSH profile and a clone made with a non-SSH profile both contain the selected local marker.
- Existing managed Git settings and clone authentication tests remain green.
- `bats tests/git-profile.bats` passes.

Completion evidence:

- Implemented `picotools.gitProfile` as the single repository-local identity key:
  - `apply_context` (`tools/bin/git-profile:950-969`) now resolves the profile name from the saved profile file and writes it once per `set` via the existing duplicate-safe helper `write_local_value` (`tools/bin/git-profile:307-313`), which performs `unset_local_value` followed by `git config --local`. The marker is never written into the saved `.gitconfig` files; `save_context` (`tools/bin/git-profile:670-716`) is unchanged and the filename remains the saved profile's identity.
  - `clone_with_profile` (`tools/bin/git-profile:1197-1218`) persists the same key in the new repository by passing `--config picotools.gitProfile=<name>` to `git clone` for both SSH and non-SSH clones. No destination-path inference is required and SSH behavior (`GIT_SSH_COMMAND` with `IdentitiesOnly=yes`) is preserved.
- Coverage added in `tests/git-profile.bats`:
  - Test 28 `set writes the repository profile marker` asserts `git config --local --get-all picotools.gitProfile` returns exactly `work` after `set`.
  - Test 29 `set replaces stale repository profile marker values` pre-seeds two duplicate `picotools.gitProfile` local values, then selects two saved profiles in sequence; the final local value is exactly the latest selected profile name with no duplicates.
  - Tests 30-31 verify the `--config picotools.gitProfile=<name>` argument is forwarded to `git clone` for SSH and non-SSH profiles.
  - Test 32 `clone persists the marker inside the cloned repository` performs a real `git clone` of a local bare repository and asserts the cloned repository's local config contains exactly the selected marker.
  - Existing managed-config tests (17-19) and clone SSH/non-SSH tests (24-25) had their URL substring assertions updated to reflect the new `clone --config key=value <url>` argv shape; the auth behavior they verify (`GIT_SSH_COMMAND` set for SSH, unset for non-SSH, URL passed through) is unchanged.
- Verification run on 2026-08-18:
  - `bash -n tools/bin/git-profile tools/bin/git-api tools/bin/git-commit tools/bin/git-api.d/common.sh tools/bin/git-api.d/http.sh tools/bin/git-api.d/spec.sh`: passed.
  - `bats tests/git-profile.bats`: 32 passed (27 baseline + 5 new), 0 failed.
  - `bats tests/git-api.bats`: 19 passed, 0 failed.
  - `bats tests/git-commit.bats`: 64 passed, 0 failed.
  - `scripts/shfmt-diff.bash`: reported no formatting diff.
  - `pre-commit run --files tools/bin/git-profile tests/git-profile.bats`: passed (shellcheck + shfmt + end-of-file etc.).
  - `pre-commit run --all-files`: passed; the unrelated concurrent README/release-setup dirty files were preserved and introduced no pre-commit failures.

### Task PROFILE-02: Add Optional Profile-Owned PAT Storage And Retrieval

Status: completed

Priority: P0

Suggested agent: Bash security engineer

Dependencies: PROFILE-01

Primary ownership:

- `tools/bin/git-profile`
- `tests/git-profile.bats`

Finding:

`git-profile` has no data-directory abstraction, secret prompt, PAT lifecycle, or repository-context retrieval command. Storing a PAT in either the saved `.gitconfig` or repository `.git/config` would mix confidential data with routinely inspected configuration.

References:

- `tools/bin/git-profile:14-32`
- `tools/bin/git-profile:91-110`
- `tools/bin/git-profile:367-422`
- `tools/bin/git-profile:670-791`
- `tools/bin/git-profile:892-941`
- `tools/bin/model-profile:119-130`
- `tools/bin/model-profile:219-227`
- `tools/bin/model-profile:410-421`
- `tools/bin/model-profile:587-600`
- `lib/picotools/prompt.sh` secret prompt helper used by `git-api` at `tools/bin/git-api:71-73`

Implementation requirements:

1. Add a data-directory and token-file abstraction using `${XDG_DATA_HOME:-$HOME/.local/share}/git-profile/<name>.token`.
2. Validate the profile name before deriving any secret path.
3. Set restrictive permissions before directory/file creation, and explicitly enforce directory mode `0700` and token file mode `0600`, including overwrite of a pre-existing permissive file.
4. Refuse to read, overwrite, or delete a token path that is a symbolic link; token lifecycle operations must not escape the intended data directory through a pre-created link.
5. Extend `create` with an optional masked PAT prompt. Blank input means no PAT.
6. Extend `update` with a PAT action that can keep, replace, add, or remove the token without ever pre-filling or displaying its current value.
7. If an existing profile is overwritten through `create` and the new PAT is blank, remove the old token so stale credentials are not silently retained.
8. Deleting a git profile must also delete its owned token file. Do not delete similarly named `git-api` credentials.
9. Add a `token` command that must run inside a Git repository, read only the local `picotools.gitProfile` marker, verify the saved profile exists, and print its PAT with no decoration.
10. `token` must fail nonzero with a precise stderr message when outside a repository, when the marker is absent, when the saved profile no longer exists, or when that profile has no PAT.
11. Add PAT configured/not-configured status to appropriate list/read/create/update summaries without revealing token bytes. Keep the concise list usable; a single `PAT` yes/no column is sufficient.
12. Never include the PAT in saved profile config, local Git config, debug output, confirmation output, tables, or error messages.

Acceptance criteria:

- Creating a profile with a PAT writes only `${XDG_DATA_HOME}/git-profile/<name>.token`; neither profile config nor repository config contains the token.
- The token directory is mode `0700` and token file is mode `0600`, including after replacing a deliberately permissive existing file.
- A pre-created token-file symlink is rejected for read, write, and delete operations without changing its target.
- Creating without a PAT leaves no token file, and overwriting with blank PAT removes any stale token.
- Updating supports add, replace, keep, and remove paths without exposing the existing value.
- `git-profile token` returns exactly the active repository profile's PAT and never chooses a profile by matching identity fields.
- Deleting the profile removes its token, while deleting or changing local repository config does not delete the saved token.
- List, read, debug, and failure outputs do not contain a test token sentinel.
- Negative tests cover missing repository, missing marker, missing profile, and missing token.
- `bats tests/git-profile.bats` passes.

Completion evidence:

- Implemented separate PAT storage for `git-profile` under `${XDG_DATA_HOME:-$HOME/.local/share}/git-profile`:
  - `tools/bin/git-profile:96-205` adds `data_dir`, `context_token_file`, `ensure_data_dir`, and the token lifecycle helpers. Secret-path derivation now validates the profile name first, enforces directory mode `0700` and file mode `0600`, and rejects symbolic-link token paths for read, write, and delete operations with non-secret errors.
  - `tools/bin/git-profile:1437-1453` adds `git-profile token`, which requires a Git repository, reads only the local `picotools.gitProfile` marker, verifies the saved profile file still exists, and prints only that profile's PAT.
- Extended `git-profile` create, update, delete, list, and read flows without exposing token bytes:
  - `tools/bin/git-profile:522-546` and `:955-964` add a PAT yes/no field to detailed and list output.
  - `tools/bin/git-profile:841-943` adds an optional masked PAT prompt to `create`, stores the PAT only in the XDG data file, and removes a stale token when overwriting an existing profile with blank PAT input.
  - `tools/bin/git-profile:1278-1309` adds an update-only PAT action menu that supports keep, add, replace, and remove without pre-filling or printing the existing secret.
  - `tools/bin/git-profile:1068-1091` makes profile deletion remove the owned PAT file while preserving the separate `git-api` credential area.
  - `tools/bin/git-profile:1105-1111` generalizes repository checks so `token` gets its own precise outside-repo error while preserving the existing `set` message.
- Coverage added in `tests/git-profile.bats`:
  - `tests/git-profile.bats:1291-1327` verifies PAT storage goes only to `${XDG_DATA_HOME}/git-profile/<name>.token`, never to saved profile config, repository config, list output, read output, or debug output.
  - `tests/git-profile.bats:1329-1359` verifies blank create leaves no token file, overwrite-with-blank removes a stale token, and permissive existing directory/file modes are repaired to `0700`/`0600`.
  - `tests/git-profile.bats:1361-1393` verifies update add, keep, replace, and remove flows without exposing token values.
  - `tests/git-profile.bats:1395-1488` verifies positive repository-context lookup plus negative `token` behavior for missing repository, missing marker, missing profile, and missing token.
  - `tests/git-profile.bats:1490-1567` verifies symlink rejection for PAT write, read, and delete operations without modifying the symlink targets or printing the token sentinel.
- Verification run on 2026-08-18:
  - `bash -n tools/bin/git-profile`: passed.
  - `bats tests/git-profile.bats`: 44 passed (32 baseline + 12 new), 0 failed.
  - `scripts/shfmt-diff.bash`: reported no formatting diff after `shfmt` normalization from pre-commit.
  - `pre-commit run --files tools/bin/git-profile tests/git-profile.bats`: passed.

## Wave 2: Secure Dynamic Git API Authentication

### Task API-01: Add A Stdin Token Override To Git API

Status: completed

Priority: P0

Suggested agent: Bash API client engineer

Dependencies: PROFILE-02

Primary ownership:

- `tools/bin/git-api`
- `tools/bin/git-api.d/common.sh` if needed
- `tests/git-api.bats`

Finding:

The requested dynamic PAT argument already exists as `--token TOKEN`, but forwarding a newly retrieved repository PAT that way exposes it in process arguments. `git-api` has no stdin-based equivalent for trusted tool composition.

References:

- `tools/bin/git-api:24-64`
- `tools/bin/git-api:407-453`
- `tools/bin/git-api.d/common.sh:257-292`
- `tests/git-api.bats:134-167`

Implementation requirements:

1. Preserve the public `--token TOKEN` behavior and precedence.
2. Add and document global `--token-stdin`, which reads one token from stdin, strips only trailing CR/LF, rejects an empty token, and sets the same highest-priority override used by `--token`.
3. Reject using `--token` and `--token-stdin` together rather than relying on argument order.
4. Never print the token in debug logs or errors.
5. Keep named-profile, environment, current-profile, and legacy-token fallback behavior unchanged when neither explicit override is supplied.

Acceptance criteria:

- A token supplied through stdin is sent as the Authorization bearer token and overrides a selected named profile.
- The token is absent from the `git-api` argument vector and command output in the integration test.
- Empty stdin and conflicting token flags fail with actionable errors that do not contain a token.
- Existing `--token` and `--profile` tests remain green.
- `bats tests/git-api.bats` passes.

Completion evidence:

- Added documented global stdin token override handling in `tools/bin/git-api`:
  - `tools/bin/git-api:37-58` documents `--token-stdin` in help output and examples.
  - `tools/bin/git-api:409-491` tracks explicit token override sources, rejects `--token` plus `--token-stdin` regardless of flag order, and resolves the stdin token only after command selection so help/version behavior stays unchanged.
- Added shared stdin token normalization in `tools/bin/git-api.d/common.sh:257-319`:
  - `git_api_read_token_stdin` reads the stdin payload once, strips only trailing CR/LF, rejects an empty token, and feeds the existing highest-precedence `GIT_API_TOKEN_OVERRIDE` path used by `git_api_token`.
  - Named-profile, environment-variable, current-profile, and legacy token-file fallback behavior remains unchanged when neither explicit override is supplied.
- Expanded `tests/git-api.bats` coverage:
  - `tests/git-api.bats:25` logs the parent `git-api` argv from the stubbed `curl` process so the integration test can assert the stdin token never appears in process arguments.
  - `tests/git-api.bats:135-197` now verifies help text documentation, stdin override precedence over a selected profile, CR/LF trimming, absence of the token from `git-api` argv and captured output, empty-stdin rejection, and conflict rejection for `--token` with `--token-stdin`.
- Verification run on 2026-08-18:
  - `bash -n tools/bin/git-api tools/bin/git-api.d/common.sh`: passed.
  - `bats tests/git-api.bats`: 22 passed (19 baseline + 3 new), 0 failed.
  - `shfmt --diff --indent 2 tools/bin/git-api tools/bin/git-api.d/common.sh tests/git-api.bats`: passed with no diff.
  - `pre-commit run --files tools/bin/git-api tools/bin/git-api.d/common.sh tests/git-api.bats`: passed.

### Task COMMIT-01: Prefer The Repository Git Profile PAT For PR Calls

Status: completed

Priority: P0

Suggested agent: Bash integration engineer

Dependencies: API-01

Primary ownership:

- `tools/bin/git-commit`
- `tests/git-commit.bats`

Finding:

`run_git_api` can forward only the globally configured `git-api` profile. It cannot resolve the active repository's git profile or use a profile-owned PAT, even though every PR-mode API call runs in repository context.

References:

- `tools/bin/git-commit:95-161`
- `tools/bin/git-commit:308-323`
- `tools/bin/git-commit:1119-1267`
- `tools/bin/git-commit:1420-1487`
- `tools/bin/git-commit:1800-1866`
- `tests/git-commit.bats:376-423`
- `tests/git-commit.bats:2077-2107`

Implementation requirements:

1. Add a `git_profile_command` resolver following the existing `model_profile_command` and `git_api_command` pattern, with `GIT_PROFILE_BIN` available for tests and installed layouts.
2. Resolve `git-profile token` once after repository validation and before the first `git-api` call in `--pr` mode.
3. Treat the expected no-marker/no-token result as no repository token and fall back without surfacing noisy lookup errors during normal PR operation.
4. When a repository token exists, feed it to every `git-api` invocation through `--token-stdin`; do not also pass `--profile`.
5. When no repository token exists, preserve the current configured `--profile` path exactly. When neither exists, invoke `git-api` without either override so its current fallback chain remains intact.
6. Forward `--debug` as today but never log the token or its stdin payload.
7. Do not retrieve a PAT for preview, apply-only, or push-only runs that do not use `git-api`.
8. Keep all default-branch fallback behavior and PR create/update behavior unchanged apart from authentication selection.

Acceptance criteria:

- With a local git profile PAT and a configured `git-api.profile`, all `repos/get`, `pulls/list`, `pulls/create`, and `pulls/update` calls use stdin token auth and none use `--profile`.
- The token sentinel does not appear in the captured `git-api` argument list, `git-commit --debug` output, or user-visible errors.
- With an active git profile but no PAT, calls use the configured `git-api.profile` exactly as before.
- With no local marker, calls use the configured `git-api.profile` exactly as before.
- With neither repository PAT nor configured profile, `git-api` receives no explicit auth selector.
- The repository PAT is retrieved once per PR run, not once per API request.
- Existing PR create, PR update, default-branch fallback, and configured-profile tests remain green.
- `bats tests/git-commit.bats` passes.

Completion evidence:

- Updated `tools/bin/git-commit` to add `git_profile_command` and a one-time repository PAT resolver for PR mode:
  - `run_commit_tool` now resolves `git-profile token` once after repository/config validation and before `resolve_pull_request_context`, so the same auth decision is reused for default-branch lookup, existing-PR lookup, and PR create/update.
  - `resolve_repository_git_api_auth` treats `Error: no git profile is recorded in this repository` and `Error: PAT not configured for profile '...'` as quiet fallback conditions, but preserves unexpected `git-profile token` failures as user-visible errors.
  - `run_git_api` now prefers `GIT_COMMIT_GIT_API_TOKEN` and passes it only via `--token-stdin`; when that token is present it does not also pass `--profile`. When no repository PAT is available, the existing configured `git-api.profile` path and bare `git-api` fallback path are unchanged.
- Expanded `tests/git-commit.bats` coverage for the new precedence contract:
  - Added a `git-profile` stub plus stdin-aware `git-api` stub logging so tests can verify `--token-stdin` usage without placing the PAT in argv.
  - Verified PR create flow uses repository-PAT stdin auth for `repos/get`, `pulls/list`, and `pulls/create`, omits `--profile`, keeps the token out of `git-api` argv and `git-commit --debug` output, and resolves `git-profile token` exactly once for the whole run.
  - Verified PR update flow uses repository-PAT stdin auth for `repos/get`, `pulls/list`, and `pulls/update`.
  - Verified fallback to configured `git-api.profile` when the active repository profile has no PAT.
  - Verified fallback to no explicit auth selector when neither repository PAT nor configured profile exists.
  - Updated the existing configured-profile PR test to stub the no-marker repository lookup and confirm the legacy `--profile work` path still applies when no repository PAT exists.
- Verification run on 2026-08-18:
  - `bash -n tools/bin/git-commit tests/git-commit.bats`: passed.
  - `bats tests/git-commit.bats`: 68 passed (64 baseline + 4 new), 0 failed.
  - `shfmt --diff --indent 2 tools/bin/git-commit tests/git-commit.bats`: passed with no diff.
  - `pre-commit run --files tools/bin/git-commit tests/git-commit.bats`: passed.

## Wave 3: Documentation And Independent Review

### Task DOC-01: Document Repository-Aware Profile Authentication

Status: completed

Priority: P2

Suggested agent: CLI documentation engineer

Dependencies: COMMIT-01

Primary ownership:

- `README.md`
- help text in the three changed tools

Finding:

Current documentation describes independent git profile, `git-api`, and `git-commit` configuration. It does not describe a repository marker, git-profile-owned PATs, or cross-tool authentication precedence.

References:

- `README.md:40-44`
- `tools/bin/git-profile:14-32`
- `tools/bin/git-api:24-64`
- `tools/bin/git-commit:29-52`

Implementation requirements:

1. Document `picotools.gitProfile`, the XDG config/data split, file-permission model, and `git-profile token` secret-output behavior.
2. Document that `set` and `clone` establish repository context.
3. Document the exact `git-commit --pr` auth precedence.
4. Document `git-api --token-stdin` and retain `--token TOKEN` documentation.
5. Warn users that `git-profile token` intentionally writes a secret to stdout and should be used only in trusted pipelines or command substitution.
6. Preserve unrelated concurrent `README.md` changes.

Acceptance criteria:

- Help output and README contracts agree with runtime behavior and tests.
- Documentation never includes a realistic PAT value.
- The storage path is described with `XDG_DATA_HOME` and its default, not as a hard-coded home path only.

Completion evidence:

- Documented the repository-aware `git-profile` contract in `README.md` while preserving the unrelated concurrent release-setup wording already present:
  - Added `git-profile` to the top-level tool table and install list (`README.md:24`, `README.md:121`).
  - Added a dedicated `git-profile` section covering `picotools.gitProfile`, the XDG config/data split, `0700`/`0600` filesystem-permission model, repository-context establishment via `set` and `clone`, and the warning that `git-profile token` prints a secret to stdout for trusted pipelines only (`README.md:43-47`).
  - Expanded the `git-commit` README entry to document the exact `--pr` auth precedence: repository git-profile PAT, then configured `git-api.profile`, then `git-api` fallback resolution (`README.md:45`).
  - Expanded the `git-api` README entry to document `--token-stdin`, its shared highest precedence with `--token`, and the unchanged fallback chain when neither explicit override is used (`README.md:47`).
- Updated help text in all three affected tools so CLI help matches the implemented behavior:
  - `tools/bin/git-profile:16-39` now documents repository marker recording for `set` and `clone`, optional PAT storage, XDG storage paths, enforced permissions, and the stdout-secret warning for `token`.
  - `tools/bin/git-api:26-54` now documents `--token-stdin` as equal-precedence to `--token` and adds an explicit auth-precedence summary.
  - `tools/bin/git-commit:31-59` now documents `--pr` auth precedence and the repository context established by `git-profile set` / `git-profile clone` through local `picotools.gitProfile`.
- Added help-output assertions so the new docs stay covered by tests:
  - `tests/git-profile.bats:231-237` checks the repository-marker and stdout-secret help text.
  - `tests/git-api.bats:139-147` checks `--token-stdin` precedence wording and the auth-precedence summary.
  - `tests/git-commit.bats:651-660` checks `picotools.gitProfile` repository-context wording and `git-api.profile` fallback precedence in `--pr` help.
- Verification run on 2026-08-18:
  - `bash -n tools/bin/git-profile tools/bin/git-api tools/bin/git-commit`: passed.
  - `bats tests/git-profile.bats tests/git-api.bats tests/git-commit.bats`: 134 passed, 0 failed.
  - `pre-commit run --files README.md tools/bin/git-profile tools/bin/git-api tools/bin/git-commit tests/git-profile.bats tests/git-api.bats tests/git-commit.bats`: passed.

### Task REVIEW-01: Perform Independent Security And Integration Review

Status: completed

Priority: P0

Suggested agent: independent Bash/security reviewer

Dependencies: DOC-01

Primary ownership:

- Review only, plus focused fixes and tests for findings

Finding:

This feature crosses persistent secret storage, repository-controlled configuration, subprocess boundaries, and an existing authentication fallback chain. A final reviewer must validate behavior rather than only inspect implementation shape.

References:

- All files and acceptance criteria in PROFILE-01 through DOC-01

Implementation requirements:

1. Verify a malicious or malformed `picotools.gitProfile` value cannot escape the data directory; profile-name validation must run before path construction.
2. Verify no PAT enters `.git/config`, saved `.gitconfig`, command arguments, debug logs, tables, errors, or test failure output.
3. Verify symlink handling does not allow a token write outside the intended data directory. Refuse unsafe token-file targets rather than following an existing symlink.
4. Verify file and directory modes after create and update under a permissive caller umask and with pre-existing permissive paths.
5. Verify precedence and fallback across PR default-branch lookup, existing-PR lookup, create, and update paths.
6. Verify unrelated dirty worktree changes were preserved.
7. Run targeted checks, full tests, syntax validation, formatting diff, and pre-commit.

Acceptance criteria:

- Every prior task's acceptance criteria has runtime or test evidence.
- `bats tests/git-profile.bats tests/git-api.bats tests/git-commit.bats` passes.
- `bash -n bin/* tools/bin/* scripts/*.bash` passes.
- `scripts/shfmt-diff.bash` reports no formatting diff.
- `pre-commit run --all-files` passes, or any unrelated pre-existing failure is recorded with exact output and ownership.
- `bats tests/*.bats` passes.
- No test or review artifact containing a PAT remains in the repository.

Completion evidence:

- Completed an independent review pass using a separate Bash/security reviewer plus local source-and-runtime verification. The review identified five concrete issues, all of which were addressed before final verification:
  - `git-api` no longer places resolved bearer tokens in child `curl` process arguments. `git_api_request` now writes the auth header to a temporary `0600` curl config file and passes only `--config <tmpfile>` on argv, while also rejecting CR/LF-bearing tokens before request construction (`tools/bin/git-api.d/http.sh:46-159`).
  - `git-api --token-stdin` now rejects multiline stdin payloads after trimming only trailing CR/LF, so it accepts exactly one token line instead of forwarding embedded newlines into the Authorization header (`tools/bin/git-api.d/common.sh:294-329`).
  - `git-profile` now treats zero-byte or CR/LF-only PAT files as not configured in both status reporting and `token` lookup, so blank token files fail with the same precise missing-PAT error instead of silently succeeding with empty stdout (`tools/bin/git-profile:146-200`).
  - `git-profile clone` now reuses the saved `core.sshCommand` directly for clone-time SSH auth, preserving paths with spaces instead of rebuilding an unescaped command string (`tools/bin/git-profile:1409-1428`).
  - The README contract now matches runtime behavior by documenting interactive `git-profile set` usage correctly and describing `git-api` named profile storage with the XDG path plus default, rather than a hard-coded home-directory-only path (`README.md:43-47`).
- Added review-driven coverage so the identified risks now have regression tests:
  - `tests/git-api.bats:24-58` logs both the parent `git-api` cmdline and the child `curl` cmdline, teaches the curl stub to read auth headers from `--config`, and keeps the PAT assertions secret-safe.
  - `tests/git-api.bats:188-215` verifies the stdin token still authenticates correctly without appearing in either argv surface and rejects multiline stdin with a precise error.
  - `tests/git-profile.bats:1053-1080` performs an integration-style clone with the real `git` binary and a stubbed `ssh` command, proving an SSH key path containing spaces survives as a single `-i` argument.
  - `tests/git-profile.bats:1522-1546` verifies blank PAT files are treated as not configured and do not cause `git-profile token` or PAT status reporting to behave as though a secret exists.
- Revalidated existing security and precedence requirements without additional code changes:
  - Malformed repository markers still cannot escape the PAT data directory because repository-context lookup validates `picotools.gitProfile` before path construction (`tools/bin/git-profile:121-126`, `tools/bin/git-profile:1444-1462`).
  - Symlink refusal and permission enforcement remain covered by the existing create/read/delete PAT lifecycle tests and the permissive-mode repair test in `tests/git-profile.bats`.
  - PR auth precedence and fallback across default-branch lookup, existing-PR lookup, PR create, and PR update remained green in the existing `git-commit` coverage (`tests/git-commit.bats`, including the repository-PAT and fallback cases added for COMMIT-01).
- Verification run on 2026-08-18 after the review fixes:
  - `bash -n bin/* tools/bin/* scripts/*.bash`: passed.
  - `scripts/shfmt-diff.bash`: reported no formatting diff.
  - `bats tests/git-profile.bats tests/git-api.bats tests/git-commit.bats`: 137 passed, 0 failed.
  - `bats tests/*.bats`: 301 passed, 0 failed.
  - `pre-commit run --all-files`: passed.
- Dirty-worktree preservation check:
  - `git status --short` after verification still showed unrelated pre-existing changes in `tests/git-commit.bats`, `tests/git-release-setup.bats`, `tools/bin/git-api`, `tools/bin/git-commit`, and `tools/bin/git-release-setup`; the review work preserved those concurrent changes rather than reverting them.
- No PAT-bearing review artifact was left in the repository worktree. The new secret-handling tests write only to Bats-managed temporary directories under `mktemp`, and no generated token files, curl config files, or captured command logs remain after test teardown.

## Dependencies And Parallelization

- Execute PROFILE-01 before PROFILE-02 because both modify the same command dispatcher and tests.
- Execute API-01 after PROFILE-02 so its stdin contract can be tested against the intended producer behavior.
- Execute COMMIT-01 after API-01 because it consumes `--token-stdin` and shares the final precedence contract.
- DOC-01 follows finalized CLI behavior and must preserve the concurrent README edits already present.
- REVIEW-01 must be performed by someone other than the main implementation owner.
- Do not run formatting or full-repository pre-commit concurrently with another agent editing shared files.

Shared hotspots are `tools/bin/git-profile`, `tests/git-profile.bats`, `tools/bin/git-commit`, `tests/git-commit.bats`, and `README.md`; serialize agents that own the same hotspot.

## Deferred Decisions

No decision blocks implementation. OS keyring-backed or encrypted-at-rest storage is deliberately deferred because all existing sibling tools use XDG data files protected by filesystem permissions. If the threat model later includes compromise of the same user account, create a separate credential-backend task rather than extending this task with an unreviewed fallback format.

## Definition Of Done

- A repository set or cloned with `git-profile` records exactly one valid `picotools.gitProfile` local value.
- A git profile can own, update, remove, and delete an optional PAT without placing it in profile or repository config.
- Token paths cannot escape the XDG data directory, token writes do not follow unsafe symlinks, and storage permissions are enforced.
- `git-profile token` retrieves only the current repository profile's PAT and has documented negative behavior.
- `git-api` accepts secure stdin token override while preserving `--token` and all existing fallback behavior.
- `git-commit --pr` uses repository PAT first, configured `git-api` profile second, and existing `git-api` resolution last for every API path.
- Tokens are absent from process arguments and all non-secret output.
- Help text, README, implementation, and tests describe the same contract.
- Targeted and full verification commands pass, with completion evidence appended to each task as work progresses.
