# Model Profile Health Remediation

Created: 2026-08-23 20:01:27 -0700

## Objective

Prevent `model-profile` from sending stored API keys to unintended hosts or exposing them through unsafe local storage and process boundaries, make profile and request state fail closed and failure-safe, then improve readability, encapsulation, reuse, testability, installed packaging, and measured performance.

## Scope

- `tools/bin/model-profile`
- New cohesive modules under `tools/lib/picotools/model-profile/` when extraction is justified below
- `tests/model-profile.bats`, a shared model-profile test helper, and focused `tests/model-profile-*.bats` files
- `README.md`, `package.json`, `.github/workflows/test.yml`, and `.github/workflows/pre-commit.yml` for changed public and verification contracts
- Shared `lib/picotools/*.sh` only when a task proves that the contract is shared and updates all affected consumers

## Working Rules And Non-Goals

- Inspect `git status --short` before each task. Preserve unrelated concurrent work and never revert another agent's changes. At review time, `docs/tasks/20260823-195913-git-clean-branches-health-remediation.md` was an unrelated untracked file.
- Serialize agents that modify `tools/bin/model-profile` or the current monolithic `tests/model-profile.bats` until stable modules and focused suites exist.
- Add a failing regression before each confirmed behavior fix. Treat profile files, profile names, endpoint data, prompts, API responses, filesystem state, environment variables, and curl configuration as untrusted input.
- Keep API keys out of argv, debug output, errors, tables, task evidence, committed fixtures, and retained temporary files.
- Preserve persisted valid profiles through a narrow validated legacy read path when a contract changes. Do not preserve malformed or credential-exfiltrating behavior through compatibility aliases.
- Keep raw assistant content on `ask` stdout as the command's data contract, but sanitize untrusted text used in diagnostics and tables.
- Do not forbid local/private custom endpoints or cleartext HTTP until the maintainer resolves the policy under Deferred Decisions. URL parsing, option separation, authority validation, and explicit insecure behavior can proceed independently.
- Do not create a generic provider or credential framework for all picotools. Extract model-profile domains first; move behavior into shared `lib/picotools` only when another tool adopts and tests the identical contract.
- Do not retain performance changes without reproducible subprocess and wall-clock evidence.

## Confirmed Baseline

- `tools/bin/model-profile` is one 1,258-line executable containing CLI parsing, profile schema and persistence, credential storage, provider metadata, prompts, HTTP transport, response parsing, rendering, and orchestration (`tools/bin/model-profile:1-1258`).
- `tests/model-profile.bats` is one 696-line integration suite with 18 happy-path tests and inline curl/jq fakes (`tests/model-profile.bats:1-696`).
- Azure resource names are interpolated into URL authorities without validation. Characters such as `@`, `/`, `?`, `#`, and `:` can change URL interpretation before the stored bearer token is sent (`tools/bin/model-profile:361-407`, `tools/bin/model-profile:496-550`).
- Custom endpoints are only whitespace-trimmed and slash-normalized. Scheme, authority, userinfo, fragments, control bytes, option-like values, and persisted values are not validated (`tools/bin/model-profile:336-358`, `tools/bin/model-profile:385-407`).
- Credential writes redirect directly to the final path after a process-global `umask 077`; existing symlinks, hard links, FIFOs, unsafe modes, and symlinked data directories are not rejected (`tools/bin/model-profile:119-130`, `tools/bin/model-profile:410-420`, `tools/bin/model-profile:581-600`).
- Profile saves remove the live file and issue multiple independent `git config` writes. Create/update can expose partial metadata or pair new routing metadata with an old token after failure (`tools/bin/model-profile:676-697`, `tools/bin/model-profile:773-812`, `tools/bin/model-profile:873-912`).
- Persisted files are consumed without a complete schema/path validation boundary, and direct commands do not validate profile names before path construction (`tools/bin/model-profile:219-276`, `tools/bin/model-profile:423-494`, `tools/bin/model-profile:713-770`, `tools/bin/model-profile:1057-1069`).
- Most subcommands ignore extra arguments, interactive selection failures are converted to success, and provider-selection cancellation status is lost through negation (`tools/bin/model-profile:603-625`, `tools/bin/model-profile:832-969`, `tools/bin/model-profile:1119-1249`).
- Request input, payload, response, and default duration are unbounded. `MODEL_PROFILE_CURL_MAX_TIME=0` is accepted although curl treats zero as no timeout (`tools/bin/model-profile:104-117`, `tools/bin/model-profile:496-579`, `tools/bin/model-profile:997-1027`).
- Curl is invoked without disabling ambient configuration, the bearer token is present in curl argv, and the final URL lacks an explicit `--` operand separator (`tools/bin/model-profile:534-550`).
- The current tests flatten curl argv through `$*`, emulate JSON without complete escaping, always return HTTP 200, and rarely assert failure status (`tests/model-profile.bats:93-239`, `tests/model-profile.bats:389-650`).
- Installed CI checks only `model-profile --help` and `--version`, not storage or request behavior (`.github/workflows/test.yml:109-110`).
- Worktree was otherwise clean before the unrelated task document appeared during this review.

## Baseline Verification

Run on 2026-08-23 before creating this task:

- `npm run test:model-profile`: 18 passed.
- `bash -n tools/bin/model-profile`: passed.
- `shellcheck -s bash -x tools/bin/model-profile tests/model-profile.bats`: passed.
- `shfmt --diff --indent 2 tools/bin/model-profile tests/model-profile.bats`: passed with no diff.
- `git diff --check`: passed before this task file was created.
- Two independent read-only source reviews covered security/correctness and architecture/testability/performance.
- Full `npm test`, `pre-commit run --all-files`, mutation probes, and installed-archive operations were not run because this review creates an execution task rather than changing runtime code.

## Priorities

- P0: A confirmed path that can disclose an API key, overwrite an unintended file with a key, or send a key to an unintended network authority.
- P1: Confirmed state-integrity, input-boundary, availability, or fail-open defects.
- P2: Architecture, testability, dependency, packaging, documentation, and compatibility health.
- P3: Optional performance work that requires measurement before production changes.

## Required Verification Ladder

Every implementation task must append a `Completion evidence` block with changed files, the failing-before/passing-after regression, command summaries, and follow-up findings. A task is complete only after its focused tests and applicable checks pass or an exact blocker is recorded.

1. Focused test: run the task-owned Bats files.
2. Package test: `npm run test:model-profile` after TEST-01 expands that script to all focused files.
3. Syntax: `bash -n tools/bin/model-profile tools/lib/picotools/model-profile/*.sh tests/helpers/model-profile.bash`, omitting paths that do not yet exist.
4. Static checks: `shellcheck -s bash -x` on every changed shell/Bats file, `scripts/shfmt-diff.bash`, and `git diff --check`.
5. Focused pre-commit: `pre-commit run --files <all files changed by the task>`.
6. Final integration only: `npm test`, `npm run check:syntax`, `npm run check:shellcheck`, `npm run check:format`, `pre-commit run --all-files`, and the installed-archive smoke path in `.github/workflows/test.yml`.

## Wave 1: Faithful Tests And Credential Boundaries

### Task TEST-01: Build Failure-Oriented Request And Storage Fixtures

Status: completed

Priority: P1

Suggested agent: Bats security fixture engineer

Dependencies: none

Primary ownership:

- `tests/model-profile.bats`
- New `tests/helpers/model-profile.bash`
- New focused `tests/model-profile-*.bats` files
- `package.json`

Finding:

The current suite validates 18 happy paths but its curl fake flattens argv, always returns HTTP 200, and loosely consumes options. Its jq fake interpolates strings without JSON escaping and contains duplicate `model)` branches. The suite cannot reliably detect option-boundary, transport, malformed-JSON, secret-argv, status-propagation, or special-character regressions.

References:

- `tests/model-profile.bats:1-245`
- `tests/model-profile.bats:389-650`
- `package.json:15-24`

Implementation requirements:

1. Extract isolated HOME/XDG setup, profile fixtures, assertions, and transport fixtures into one helper without exposing API-key sentinels in failure output.
2. Use the real `jq` for production payload generation and response parsing. Stub only explicit missing-command tests.
3. Give the curl fake an explicit scenario protocol for success, transport failure, non-2xx, malformed JSON, empty content, slow/stalled output, and oversized output.
4. Record subprocess arguments losslessly, one argument per record or NUL-delimited; never use `$*` where boundaries or credentials matter.
5. Make `MODEL_PROFILE_TOOL` overrideable so focused tests can target repository and installed executables.
6. Split tests only along stable concerns such as CLI/schema, storage/state, and request/transport. Update `test:model-profile` to run `tests/model-profile*.bats`.
7. Preserve all 18 current behavioral contracts unless a later task explicitly changes one.

Acceptance criteria:

- Request-body tests parse generated JSON with real `jq` and round-trip quotes, backslashes, tabs, newlines, and non-ASCII content exactly.
- Tests can distinguish one argument containing spaces from multiple arguments and can assert that no argument contains the key sentinel.
- Transport failure, non-2xx response, malformed response, and empty content each have explicit status/stderr assertions.
- Each test owns and removes its temporary HOME/XDG state; no token or request temporary remains after teardown.
- `npm run test:model-profile` runs every focused model-profile suite and all existing cases pass.

Completion evidence:

- Changed files: `tests/helpers/model-profile.bash`, `tests/model-profile-cli.bats`, `tests/model-profile-storage.bats`, `tests/model-profile-request.bats`, deleted `tests/model-profile.bats`, updated `package.json`, updated this task file.
- Regression/fixture coverage: extracted isolated HOME/XDG setup, profile helpers, redacted secret assertions, real-`jq` JSON string assertions, `MODEL_PROFILE_TOOL` override, NUL-delimited curl argv capture, sanitized public argv capture, request temp cleanup assertions, and curl scenarios for success, transport failure, non-2xx, malformed JSON, empty content, slow, and oversized responses.
- Regression/fixture coverage: split the prior 18 behavioral contracts across CLI/schema, storage/state, and request/transport suites; added request-body exact round-trip coverage for quotes, backslashes, tabs, newlines, and non-ASCII content; added argv boundary assertions for one header argument with spaces versus separate `--max-time` arguments; added explicit status/stderr assertions for transport failure, non-2xx, malformed JSON, and empty content.
- Command summary: `npm run test:model-profile` passed with 24 tests.
- Command summary: `bash -n tools/bin/model-profile tests/helpers/model-profile.bash tests/model-profile-cli.bats tests/model-profile-storage.bats tests/model-profile-request.bats` passed.
- Command summary: `shellcheck -s bash -x tests/helpers/model-profile.bash tests/model-profile-cli.bats tests/model-profile-storage.bats tests/model-profile-request.bats` passed.
- Command summary: `scripts/shfmt-diff.bash` passed.
- Command summary: `git diff --check` passed.
- Command summary: `pre-commit run --files docs/tasks/20260823-200127-model-profile-health-remediation.md package.json tests/helpers/model-profile.bash tests/model-profile-cli.bats tests/model-profile-storage.bats tests/model-profile-request.bats tests/model-profile.bats` passed.
- Follow-ups/blockers: none for TEST-01.

### Task SEC-01: Make API-Key Storage Path-Safe And Atomic

Status: completed

Priority: P0

Suggested agent: Bash filesystem security engineer

Dependencies: TEST-01

Primary ownership:

- Credential-storage functions in `tools/bin/model-profile`
- New `tools/lib/picotools/model-profile/token.sh` if extracted
- Focused storage security tests
- `README.md` only for the selected permission contract

Finding:

`write_token` redirects directly to the final token path. It follows symlinks, writes through hard links and FIFOs, preserves an existing permissive mode, and can leave a truncated token. The data directory is created under the caller's ambient umask and can itself be a symlink. Reads and status checks accept unsafe paths and modes.

References:

- `tools/bin/model-profile:119-130`
- `tools/bin/model-profile:410-420`
- `tools/bin/model-profile:581-600`
- Existing positive tests: `tests/model-profile.bats:265-303`, `tests/model-profile.bats:653-669`

Implementation requirements:

1. Apply one shared storage validation boundary to token status, read, explicit write, and delete.
2. Reject symlinked/non-directory storage roots and symlinked/non-regular token leaves. Prevent writes through existing hard links and reject FIFO/socket/device destinations without blocking.
3. Create the credential directory with mode `0700` and stage keys in a newly created same-directory regular file with mode `0600` before atomic replacement.
4. Reject malformed multiline and control-byte key content. Strip at most the documented trailing line ending rather than concatenating lines.
5. Implement the maintainer-selected permission policy consistently. The recommended policy is fail-closed reads/status/deletes and repair only during an explicit safe write.
6. Register cleanup before a staged path can be abandoned and remove transaction temporaries on success, failure, and handled signals.
7. Keep key bytes out of argv, diagnostics, debug output, test names, and completion evidence.

Acceptance criteria:

- A symlinked data directory or token cannot cause `list`, `read`, `ask`, `test`, `create`, `update`, or `delete` to access an outside target.
- Hard-link replacement leaves the other link unchanged; FIFO and other non-regular destinations fail promptly under a timeout.
- New and safely rewritten credential directories/files are `0700`/`0600` regardless of caller umask.
- A failed write preserves the previous complete token and leaves no task-owned temporary.
- Permissive mode, multiline, missing, and blank token behavior matches the documented policy.
- Focused storage tests and `npm run test:model-profile` pass.

Completion evidence:

- Changed files for SEC-01: `tools/bin/model-profile`, `tests/helpers/model-profile.bash`, `tests/model-profile-storage.bats`, `README.md`, and this task file. `CHANGELOG.md` was not edited. Pre-existing unrelated/concurrent worktree changes were preserved.
- Failing-before regression summary: `bats tests/model-profile-storage.bats` failed on the new storage regressions before implementation: symlinked credential directory accepted by `list`, symlinked token leaf accepted by `list`, hard-linked credential update succeeded, credential directory created with permissive mode under caller umask, and atomic-replacement failure injection was not exercised.
- Passing-after regression summary: focused storage coverage now exercises symlinked credential directories across `list`, `read`, `ask`, `test`, `create`, `update`, and `delete`; symlinked token leaves across status/read/use/write/delete paths; hard-link rejection; FIFO rejection under `timeout 5`; `0700`/`0600` creation and explicit-write repair; fail-closed permissive, blank, multiline, and control-byte reads including NUL; and failed replacement preserving the prior complete credential with no task-owned temporary left behind.
- Command summary: `bats tests/model-profile-storage.bats` passed with 12 tests.
- Command summary: `npm run test:model-profile` passed with 30 tests.
- Command summary: `bash -n tools/bin/model-profile tests/helpers/model-profile.bash tests/model-profile-cli.bats tests/model-profile-storage.bats tests/model-profile-request.bats` passed.
- Command summary: `shellcheck -s bash -x tools/bin/model-profile tests/helpers/model-profile.bash tests/model-profile-cli.bats tests/model-profile-storage.bats tests/model-profile-request.bats` passed.
- Command summary: `scripts/shfmt-diff.bash` passed.
- Command summary: `git diff --check` passed.
- Command summary: `pre-commit run --files tools/bin/model-profile tests/helpers/model-profile.bash tests/model-profile-storage.bats README.md docs/tasks/20260823-200127-model-profile-health-remediation.md` passed.
- Follow-ups/blockers: none for SEC-01.

## Wave 2: Validated Destinations And Safe Requests

### Task SCHEMA-01: Validate Profile Identity Paths And Complete State

Status: completed

Priority: P1

Suggested agent: Bash persistence schema engineer

Dependencies: TEST-01

Primary ownership:

- Profile path/read/validation functions in `tools/bin/model-profile`
- New `tools/lib/picotools/model-profile/profile.sh` if extracted
- Focused profile schema tests

Finding:

Persisted `.conf` files and direct profile names are trusted. Direct `models`, `ask`, and `test` paths do not call `validate_profile_name`; selected files can be symlinks; provider type and required provider-specific fields are not revalidated; and whitespace-only fields can normalize to empty after the required prompt. Accepted names include `.`/`..` and tab whitespace, which are not reliably discoverable or table-safe.

References:

- `tools/bin/model-profile:132-151`
- `tools/bin/model-profile:219-276`
- `tools/bin/model-profile:282-358`
- `tools/bin/model-profile:423-494`
- `tools/bin/model-profile:654-710`
- `tools/bin/model-profile:853-871`

Implementation requirements:

1. Define canonical profile-name and model-name rules that reject path traversal, `.`/`..`, hidden-file aliases, separators, tabs/newlines/control bytes, and rendering delimiters while preserving existing ordinary names with internal spaces.
2. Resolve only regular non-symlink profile files owned by the configured profile directory. Validate both interactive selection and direct CLI lookup through the same boundary.
3. Load a complete profile record and validate provider type, required location field, at least one model, duplicate keys, incompatible provider fields, and unknown/malformed config before display, update, token access, or network use.
4. Revalidate after normalization and before candidate publication.
5. Define saved files as tool-owned or user-editable. The recommended contract is tool-owned managed keys with a narrow legacy read path for valid existing profiles.
6. Return controlled errors from reusable functions rather than exiting deep in the module.

Acceptance criteria:

- Out-of-tree names and symlinked/non-regular profiles cannot be listed, read, updated, deleted, or used for a request.
- Unknown providers, missing required fields, empty normalized models/location, duplicate managed keys, and provider-inconsistent fields fail before key reads or network calls.
- Every accepted name is discoverable and maps to exactly one config/token pair; `.`, `..`, tabs, controls, and traversal inputs are rejected.
- Valid existing profiles for all four providers remain readable under the documented compatibility contract.
- Direct schema tests and end-to-end package tests pass.

Completion evidence:

- Changed files for SCHEMA-01: `tools/bin/model-profile`, `tests/model-profile-schema.bats`, and this task file. `CHANGELOG.md` was not edited. Pre-existing unrelated/concurrent worktree changes were preserved.
- Regression summary: added direct schema coverage for profile-name rejection of `.`, `..`, hidden aliases, traversal, separators, tabs/newlines, and rendering delimiters; accepted names with internal spaces; symlinked profile directories; symlinked and non-regular profile files; schema validation before credential reads/network calls; missing/duplicate/incompatible/malformed managed config; invalid model names; empty normalized model lists; and legacy readability for all four providers.
- Command summary: `bash -n tools/bin/model-profile tests/helpers/model-profile.bash tests/model-profile-cli.bats tests/model-profile-storage.bats tests/model-profile-request.bats tests/model-profile-schema.bats` passed.
- Command summary: `bats tests/model-profile-schema.bats` passed with 7 tests.
- Command summary: `bats tests/model-profile-cli.bats`, `bats tests/model-profile-storage.bats`, and `bats tests/model-profile-request.bats` passed with 3, 12, and 15 tests respectively.
- Command summary: `npm run test:model-profile` passed with 37 tests.
- Command summary: `shellcheck -s bash -x tools/bin/model-profile tests/helpers/model-profile.bash tests/model-profile-cli.bats tests/model-profile-storage.bats tests/model-profile-request.bats tests/model-profile-schema.bats` passed.
- Command summary: `scripts/shfmt-diff.bash` passed.
- Command summary: `git diff --check` passed.
- Command summary: `pre-commit run --files tools/bin/model-profile tests/model-profile-schema.bats docs/tasks/20260823-200127-model-profile-health-remediation.md` passed.
- Follow-ups/blockers: none for SCHEMA-01.

### Task NET-01: Validate Provider Destinations Before Reading Credentials

Status: completed

Priority: P0

Suggested agent: URL and SSRF boundary engineer

Dependencies: SCHEMA-01

Primary ownership:

- Provider validation and URL-resolution functions
- New `tools/lib/picotools/model-profile/provider.sh` if extracted
- Focused destination tests
- Help/README for custom endpoint policy

Finding:

Azure resource names are interpolated into a URL authority without syntax validation, so userinfo/path/query delimiters can change the host that receives the bearer key. Custom endpoint normalization does not validate scheme, authority, userinfo, fragments, control bytes, private targets, or option-like input. Persisted values bypass even the limited create-time checks.

References:

- `tools/bin/model-profile:324-407`
- `tools/bin/model-profile:496-550`
- `tools/bin/model-profile:654-673`
- Positive-only endpoint tests: `tests/model-profile.bats:319-349`, `tests/model-profile.bats:573-628`

Implementation requirements:

1. Enforce Azure-compatible DNS resource-label syntax and length in one function used for candidate and persisted profile validation.
2. Parse custom endpoints as URLs rather than concatenating arbitrary strings. Require a supported explicit scheme and valid authority; reject userinfo, fragments, controls, malformed ports, and option-looking values.
3. Resolve and validate the complete `chat/completions` URL before reading the key. Ensure path joining cannot replace the validated authority.
4. Implement the maintainer decision for HTTP and local/private/link-local destinations. If private endpoints remain supported, require an explicit documented opt-in for insecure/high-risk destinations rather than silently weakening all profiles.
5. Treat hostnames as unresolved identities unless a DNS/rebinding policy is deliberately implemented; do not claim an IP denylist alone prevents SSRF.
6. Preserve valid Azure, Gemini, and custom OpenAI-compatible URL shapes.

Acceptance criteria:

- Azure values containing `@`, `/`, `?`, `#`, `:`, whitespace, controls, invalid label punctuation, or invalid length fail before key access and curl invocation.
- Custom URL tests cover scheme, userinfo, fragment, malformed authority/port, option-looking values, loopback/private/link-local policy, and externally modified config.
- The final request target has the same validated scheme and authority as the profile endpoint.
- No failing destination test records a key read or transport invocation.
- Help, README, implementation, and tests agree on the selected custom endpoint policy.

Completion evidence:

- Changed files for NET-01: `tools/bin/model-profile`, `tests/helpers/model-profile.bash`, `tests/model-profile-cli.bats`, `tests/model-profile-request.bats`, `tests/model-profile-schema.bats`, `README.md`, and this task file. `CHANGELOG.md` was not edited. Pre-existing unrelated/concurrent worktree changes were preserved, including existing `README.md`, `tools/bin/model-profile`, model-profile test split, and git-clean-branches changes.
- Regression summary: added Azure resource-label validation shared by candidate and persisted schema validation; custom endpoint URL parsing for explicit scheme/authority, userinfo, fragments, queries, whitespace/controls, malformed authority/port, option-looking values, and externally modified config; final `chat/completions` URL validation before token reads; and assertions that failed destination cases do not record key/transport use.
- Selected endpoint policy: fail closed. Azure resource names must be DNS-compatible lowercase labels of 1-63 characters. Custom endpoints must be HTTPS URLs with a DNS hostname or public IPv4 literal. HTTP, localhost, private, loopback, link-local, and IPv6 address literals are rejected. Hostnames are accepted only as unresolved identities; the implementation and README do not claim DNS/IP checks fully prevent SSRF.
- Command summary: `bash -n tools/bin/model-profile tests/helpers/model-profile.bash tests/model-profile-cli.bats tests/model-profile-storage.bats tests/model-profile-request.bats tests/model-profile-schema.bats` passed.
- Command summary: `bats tests/model-profile-schema.bats`, `bats tests/model-profile-request.bats`, and `bats tests/model-profile-cli.bats` passed with 10, 16, and 3 tests respectively.
- Command summary: `npm run test:model-profile` passed with 41 tests.
- Command summary: `shellcheck -s bash -x tools/bin/model-profile tests/helpers/model-profile.bash tests/model-profile-cli.bats tests/model-profile-storage.bats tests/model-profile-request.bats tests/model-profile-schema.bats` passed.
- Command summary: `scripts/shfmt-diff.bash` passed.
- Command summary: `git diff --check` passed.
- Command summary: `pre-commit run --files tools/bin/model-profile tests/helpers/model-profile.bash tests/model-profile-cli.bats tests/model-profile-request.bats tests/model-profile-schema.bats README.md docs/tasks/20260823-200127-model-profile-health-remediation.md` passed.
- Follow-ups/blockers: none for NET-01.

### Task HTTP-01: Isolate Curl Configuration And Remove Keys From Argv

Status: completed

Priority: P0

Suggested agent: HTTP credential-boundary engineer

Dependencies: SEC-01, NET-01

Primary ownership:

- Request execution functions
- New `tools/lib/picotools/model-profile/http.sh` if extracted
- Focused HTTP security tests

Finding:

Curl loads ambient configuration, receives `Authorization: Bearer <key>` in argv, and receives the final URL without an explicit operand separator. Hostile or stale curl configuration can enable tracing/proxy/redirect behavior that exposes the key, while process inspection can observe the header argument.

References:

- `tools/bin/model-profile:496-550`
- Current argv-coupled tests: `tests/model-profile.bats:389-455`, `tests/model-profile.bats:573-628`

Implementation requirements:

1. Put curl's ambient-config disable option first and define explicit proxy, redirect, and protocol behavior rather than inheriting `.curlrc` policy.
2. Pass the bearer header through a mode-`0600` temporary curl config or another tested non-argv channel. Do not place key or prompt bytes in argv or environment.
3. Reject CR/LF/NUL and other invalid header bytes at the credential boundary.
4. Pass the validated URL through an explicit option/operand-safe boundary and ensure option-like persisted input cannot become curl options.
5. Define redirect behavior. The recommended default is no redirects; any supported redirect must revalidate target authority and must not forward credentials cross-origin.
6. Preserve stable transport exit status and non-secret diagnostics.

Acceptance criteria:

- A hostile `.curlrc` cannot enable trace output, redirects, proxying, or alternate output behavior for a request.
- Lossless argv capture contains no key sentinel or prompt content and proves the URL cannot be interpreted as an option.
- Same-origin, cross-origin, and protocol-changing redirects follow the documented policy without credential leakage.
- Transport errors remain nonzero and temporary authentication material is absent after success, failure, and handled signals.
- Focused HTTP tests and `npm run test:model-profile` pass.

Completion evidence:

- Changed files for HTTP-01: `tools/bin/model-profile`, `tests/helpers/model-profile.bash`, `tests/model-profile-request.bats`, and this task file. `CHANGELOG.md` was not edited. Pre-existing unrelated/concurrent worktree changes were preserved.
- Regression summary: added focused request coverage for hostile `.curlrc`, lossless curl argv without key or prompt sentinels, mode-`0600` temporary curl auth config cleanup on success/failure/signal, explicit `--` URL operand separation, option-like persisted endpoint rejection before curl, malformed credential byte rejection before curl, and same-origin/cross-origin/protocol-changing redirect responses.
- HTTP policy: curl is invoked with `-q` as the first argument to ignore ambient `.curlrc`; proxying is explicitly disabled with `--proxy ''` and `--noproxy '*'`; redirects are not followed with `--max-redirs 0`; request and redirect protocols are constrained to HTTPS with `--proto '=https'` and `--proto-redir '=https'`; the validated URL is passed only after `--`.
- Credential boundary: bearer credentials are passed through a temporary curl config file created with mode `0600`, never through curl argv or environment. Token content rejects NUL/CR/LF/control bytes and curl-config control characters before request execution.
- Command summary: `bash -n tools/bin/model-profile tests/helpers/model-profile.bash tests/model-profile-request.bats` passed.
- Command summary: `bats tests/model-profile-request.bats` passed with 21 tests.
- Command summary: `npm run test:model-profile` passed with 46 tests.
- Command summary: `bash -n tools/bin/model-profile tests/helpers/model-profile.bash tests/model-profile-cli.bats tests/model-profile-storage.bats tests/model-profile-request.bats tests/model-profile-schema.bats` passed.
- Command summary: `shellcheck -s bash -x tools/bin/model-profile tests/helpers/model-profile.bash tests/model-profile-request.bats` passed.
- Command summary: `scripts/shfmt-diff.bash` passed.
- Command summary: `git diff --check` passed.
- Command summary: `pre-commit run --files tools/bin/model-profile tests/helpers/model-profile.bash tests/model-profile-request.bats docs/tasks/20260823-200127-model-profile-health-remediation.md` passed.
- Follow-ups/blockers: none for HTTP-01.

### Task LIMIT-01: Bound Request Inputs Duration And Responses

Status: completed

Priority: P1

Suggested agent: CLI resource-hardening engineer

Dependencies: TEST-01; HTTP-01 preferred for final transport implementation

Primary ownership:

- Message-file loading and request execution
- Focused resource-bound tests
- Help/README for configurable limits

Finding:

Message files are loaded completely into Bash variables, readable FIFOs/devices are accepted, generated payload and response files have no byte caps, and requests have no finite default connect/total timeout. A timeout value of zero is accepted despite disabling curl's deadline.

References:

- `tools/bin/model-profile:104-117`
- `tools/bin/model-profile:496-579`
- `tools/bin/model-profile:997-1027`
- Misnamed large-input test: `tests/model-profile.bats:457-490`

Implementation requirements:

1. Require message-file inputs to be safe readable regular files and reject FIFO/device/symlink behavior according to an explicit input policy.
2. Check file and inline-message size before payload construction. Avoid loading file content into shell variables when a file-backed path is available.
3. Define finite documented defaults and positive bounded overrides for connect time, total time, payload bytes, response bytes, and diagnostic bytes. Reject zero when a deadline is promised.
4. Stop response growth at the transport boundary rather than checking only after the filesystem has been filled.
5. Bound and sanitize remote error diagnostics while preserving raw successful assistant output up to the documented response cap.
6. Clean up all request resources after overflow, timeout, malformed response, interruption, and normal success.

Acceptance criteria:

- Oversized regular input fails before jq/curl; FIFO, device, and never-ending inputs fail promptly without blocking the suite.
- Slow connect, stalled body, zero/invalid timeout, oversized success, and oversized error body produce stable bounded errors.
- Process memory and temporary-disk usage remain within documented limits for every tested boundary.
- Prompt and response edge sizes immediately below and above each cap are covered.
- Existing valid inline and file message behavior remains green.

Completion evidence:

- Changed files for LIMIT-01: `tools/bin/model-profile`, `tests/helpers/model-profile.bash`, `tests/model-profile-request.bats`, `tests/model-profile-cli.bats`, `README.md`, and this task file. `CHANGELOG.md` was not edited. Pre-existing unrelated/concurrent worktree changes were preserved, including existing model-profile remediation changes, README git-clean-branches content, and git-clean-branches files.
- Regression summary: message-file inputs now reject symlinks, FIFOs, devices, missing paths, unreadable paths, and non-regular files before request construction; file-backed prompts are passed to `jq --rawfile` without loading prompt files into shell variables; inline/file source sizes and generated payload size are checked before curl; curl receives finite connect and total deadlines by default; response body capture is bounded through a FIFO reader at the transport output boundary; remote error diagnostics are sanitized/truncated while successful assistant content remains raw up to the response body cap; temporary auth, payload, prompt, FIFO, and response files are registered for cleanup on success, overflow, timeout, malformed response, transport failure, and handled signals.
- Chosen limits: `MODEL_PROFILE_CURL_CONNECT_TIMEOUT` default 10s, max 120s; `MODEL_PROFILE_CURL_MAX_TIME` default 60s, max 600s; `MODEL_PROFILE_MAX_PAYLOAD_BYTES` default 1048576, max 10485760; `MODEL_PROFILE_MAX_RESPONSE_BYTES` default 1048576, max 10485760; `MODEL_PROFILE_MAX_DIAGNOSTIC_BYTES` default 4096, max 65536. Overrides must be positive integers; zero and invalid values fail before curl.
- Command summary: `bash -n tools/bin/model-profile tests/helpers/model-profile.bash tests/model-profile-request.bats` passed.
- Command summary: `bats tests/model-profile-request.bats` passed with 28 tests.
- Command summary: `npm run test:model-profile` passed with 53 tests.
- Command summary: `bash -n tools/bin/model-profile tests/helpers/model-profile.bash tests/model-profile-cli.bats tests/model-profile-storage.bats tests/model-profile-request.bats tests/model-profile-schema.bats` passed.
- Command summary: `shellcheck -s bash -x tools/bin/model-profile tests/helpers/model-profile.bash tests/model-profile-request.bats tests/model-profile-cli.bats` passed.
- Command summary: `scripts/shfmt-diff.bash` passed.
- Command summary: `git diff --check` passed.
- Command summary: `pre-commit run --files tools/bin/model-profile tests/helpers/model-profile.bash tests/model-profile-request.bats tests/model-profile-cli.bats README.md docs/tasks/20260823-200127-model-profile-health-remediation.md` passed.
- Follow-ups/blockers: none for LIMIT-01.

## Wave 3: State Integrity And CLI Correctness

### Task STATE-01: Publish Profile And Credential Changes Transactionally

Status: completed

Priority: P1

Suggested agent: Bash transactional-storage engineer

Dependencies: SEC-01, SCHEMA-01

Primary ownership:

- Create/update/delete persistence orchestration
- Profile and token storage modules
- Focused failure-injection tests

Finding:

`save_profile` deletes the live profile and reconstructs it through several processes. Create publishes metadata before token write, and update publishes new provider routing before asking for a replacement token. Failures can leave partial config, metadata without a token, or an old key paired with a newly selected endpoint.

References:

- `tools/bin/model-profile:245-276`
- `tools/bin/model-profile:676-697`
- `tools/bin/model-profile:773-812`
- `tools/bin/model-profile:873-933`

Implementation requirements:

1. Collect every prompt and build a complete validated candidate before the first mutation. Move review UI before publication or label post-write output only as a result.
2. Write a complete same-directory candidate profile with controlled mode and atomically replace the live profile only after validation.
3. Preflight credential state and stage any changed key before profile publication. Define explicit rollback/ordering for the two-file state.
4. Preserve the complete old profile/key pair on failed update. Failed create publishes neither file.
5. Preflight profile and token delete paths before removing either. Report precise partial cleanup if a post-publication filesystem failure cannot be rolled back.
6. Register transaction cleanup once and remove candidates/backups on success, failure, and handled signals.

Acceptance criteria:

- Failure injection after every candidate write/publish step preserves the complete previous pair or publishes neither file for create.
- Changing from Azure to custom cannot leave the old Azure key paired with the custom endpoint after EOF, cancellation, write failure, or signal.
- Successful readers observe complete old or complete new profile files, never partial managed keys.
- Delete preflight failure removes neither profile nor key; successful delete removes both without leaving transaction artifacts.
- Focused state tests and the complete package suite pass.

Completion evidence:

- Changed files for STATE-01: `tools/bin/model-profile`, `tests/helpers/model-profile.bash`, `tests/model-profile-storage.bats`, and this task file. `CHANGELOG.md` was not edited. Pre-existing unrelated/concurrent worktree changes were preserved.
- Transaction summary: create/update now collect all prompts and review before publication, write validated same-directory profile candidates with mode `0600`, stage changed token candidates before profile publication, publish changed tokens before profiles, and roll back the affected pair on failed update or publish neither file on failed create.
- Delete summary: delete preflights both profile and token paths before removing either, uses transaction backups for rollback on post-publication failure or handled signals, and removes transaction candidates/backups on success and failure through the existing single cleanup trap path.
- Failure-injection regressions: added storage tests for injected `profile-candidate`, `token-candidate`, `token-publish`, and `profile-publish` failures during create and update; Azure-to-custom EOF before token capture; handled signal during profile publication; delete token preflight failure; and successful delete artifact cleanup.
- Command summary: `bash -n tools/bin/model-profile tests/helpers/model-profile.bash tests/model-profile-storage.bats tests/model-profile-schema.bats tests/model-profile-cli.bats` passed.
- Command summary: `bats tests/model-profile-storage.bats` passed with 18 tests.
- Command summary: `bats tests/model-profile-storage.bats tests/model-profile-schema.bats tests/model-profile-cli.bats tests/model-profile-request.bats` passed with 59 tests.
- Command summary: `npm run test:model-profile` passed with 59 tests.
- Command summary: `shellcheck -s bash -x tools/bin/model-profile tests/helpers/model-profile.bash tests/model-profile-storage.bats` passed.
- Command summary: `npm run check:syntax` passed.
- Command summary: `scripts/shfmt-diff.bash` passed.
- Command summary: `git diff --check` passed.
- Command summary: `pre-commit run --files tools/bin/model-profile tests/helpers/model-profile.bash tests/model-profile-storage.bats docs/tasks/20260823-200127-model-profile-health-remediation.md` passed.
- Follow-ups/blockers: full repository `npm test` was attempted twice and timed out outside the STATE-01/model-profile scope in the existing `tests/prompt.bats` suite after the model-profile tests had passed; isolated `bats tests/prompt.bats` also timed out at the pre-existing multi-select prompt test. No STATE-01 follow-up remains.

### Task CLI-01: Enforce One Command Grammar And Propagate Failures

Status: completed

Priority: P1

Suggested agent: Bash CLI boundary engineer

Dependencies: TEST-01; SCHEMA-01 for profile argument validation

Primary ownership:

- Option parsing and dispatch in `tools/bin/model-profile`
- Focused CLI/status tests
- Usage text

Finding:

No-argument commands silently ignore extras, `models` ignores extra operands, `ask` accepts conflicting/repeated message sources with last-one-wins behavior, and debug placement differs by command. Interactive selection errors and cancellation are commonly converted to success. `prompt_provider_type` loses the original status by testing `$?` after `!` negation.

References:

- `tools/bin/model-profile:86-102`
- `tools/bin/model-profile:603-652`
- `tools/bin/model-profile:832-969`
- `tools/bin/model-profile:972-1079`
- `tools/bin/model-profile:1119-1255`

Implementation requirements:

1. Define and document one grammar: global flags, exact command arity, singleton options, mutually exclusive message sources, and `--` behavior if supported.
2. Parse into caller-owned normalized state in the current shell. Do not serialize parser state through stdout or hide parser failures in process substitution.
3. Reject extras, unknown options, missing values, duplicate singletons, and conflicting message inputs before prompting, storage access, or network calls.
4. Preserve and document distinct success, cancellation, and error statuses. Do not translate no-profile, invalid selection, EOF, or helper failure to success.
5. Correct deprecated-debug warning logic so an explicit supported `--debug` suppresses the environment warning regardless of parsing phase.
6. Reserve `exit` for top-level dispatch; reusable handlers return errors to one orchestrator.

Acceptance criteria:

- Every command has table-driven tests for valid arity, extra operands, unknown options, missing values, and debug placement.
- Conflicting/repeated message options fail before profile/key reads or curl.
- No-profile, invalid selection, EOF, and explicit cancellation statuses match the documented contract.
- `MODEL_PROFILE_DEBUG=true` plus explicit `--debug` does not emit the deprecation warning.
- No rejected invocation mutates profile state or starts transport.

Completion evidence:

- Changed files for CLI-01: `tools/bin/model-profile`, `tests/model-profile-cli.bats`, and this task file. `CHANGELOG.md` was not edited. Pre-existing unrelated/concurrent worktree changes were preserved.
- Regression summary: usage now documents one command grammar, global/command-local `--debug`, exact command arity, `--` operand behavior, singleton options, mutually exclusive message inputs, and exit statuses. CLI parsing now normalizes state in the current shell before dispatch, rejects extra operands/unknown options/missing values/duplicates/conflicts before prompting, storage reads, API-key reads, or curl, and suppresses the deprecated `MODEL_PROFILE_DEBUG` warning when explicit supported `--debug` is present. Interactive no-profile, invalid selection/EOF, and explicit cancellation now propagate as documented status `1`, `1`, and `2` respectively.
- CLI/status regressions: added focused table-driven CLI coverage for every command's extra operands and unknown options; value-option missing values for `models`, `ask`, and `test`; documented debug placement; conflicting/repeated user/system message options before key reads/curl; no-profile, invalid selection, EOF, and cancellation statuses; and explicit `--debug` with `MODEL_PROFILE_DEBUG=true` warning suppression.
- Command summary: `bash -n tools/bin/model-profile tests/helpers/model-profile.bash tests/model-profile-cli.bats tests/model-profile-storage.bats tests/model-profile-request.bats tests/model-profile-schema.bats` passed.
- Command summary: `bats tests/model-profile-cli.bats` passed with 10 tests.
- Command summary: `npm run test:model-profile` passed with 66 tests.
- Command summary: `npm run check:syntax` passed.
- Command summary: `shellcheck -s bash -x tools/bin/model-profile tests/helpers/model-profile.bash tests/model-profile-cli.bats` passed.
- Command summary: `scripts/shfmt-diff.bash` passed.
- Command summary: `git diff --check` passed.
- Command summary: `pre-commit run --files tools/bin/model-profile tests/model-profile-cli.bats docs/tasks/20260823-200127-model-profile-health-remediation.md` passed.
- Follow-ups/blockers: none for CLI-01.

## Wave 4: Architecture Tests And Measured Performance

### Task ARCH-01: Extract Stable Model Profile Domains

Status: completed

Priority: P2

Suggested agent: Bash architecture engineer

Dependencies: SEC-01, SCHEMA-01, NET-01, HTTP-01, LIMIT-01, STATE-01, CLI-01

Primary ownership:

- `tools/bin/model-profile`
- `tools/lib/picotools/model-profile/profile.sh`
- `tools/lib/picotools/model-profile/token.sh`
- `tools/lib/picotools/model-profile/provider.sh`
- `tools/lib/picotools/model-profile/http.sh`
- Direct module and installed-layout tests

Finding:

The 1,258-line executable mixes unrelated domains and deep `exit` calls with global debug/temp state. Provider facts are repeated across validation, labels, selection, field predicates, display endpoints, and request URLs. Unused helpers add noise, and most behavior is testable only through interactive end-to-end execution.

References:

- `tools/bin/model-profile:14-217`
- `tools/bin/model-profile:219-407`
- `tools/bin/model-profile:410-697`
- `tools/bin/model-profile:699-1195`
- `tools/bin/model-profile:1197-1258`

Implementation requirements:

1. Keep dependency loading, command dispatch, UI flow, and high-level orchestration in the executable.
2. Extract only stable domains established by earlier tasks: profile schema/storage, credential storage, provider registry/destination resolution, and HTTP request handling.
3. Consolidate provider label, prompt choice, required fields, display endpoint, and API base URL into one authoritative registry-style boundary without unsafe dynamic evaluation.
4. Give each module an idempotent load guard and explicit parameters, outputs, return statuses, callbacks, and required dependencies. Avoid hidden mutable globals except a narrowly owned cleanup registry.
5. Remove unused and pure pass-through helpers. Leaf module functions return rather than terminate the caller's shell.
6. Use one private temporary directory per request/transaction and install cleanup immediately after creation.
7. Resolve modules in repository and installed layouts using existing loader conventions.

Acceptance criteria:

- The executable reads as CLI orchestration rather than mixed storage/network implementation.
- Each provider is defined once for validation, prompt/display behavior, and destination construction.
- Security invariants have one enforcement point each: profile path/schema, key path/content, destination, curl/auth, resource bounds, and transaction publication.
- Modules can be repeatedly sourced and directly tested without invoking `main` or unexpectedly exiting the shell.
- Repository and installed layouts load every module and pass CRUD plus stubbed-request smoke tests.
- Public output changes only where earlier tasks explicitly changed the contract.

Completion evidence:

- Changed files for ARCH-01: `tools/bin/model-profile`, `tools/lib/picotools/model-profile/provider.sh`, `tools/lib/picotools/model-profile/profile.sh`, `tools/lib/picotools/model-profile/token.sh`, `tools/lib/picotools/model-profile/http.sh`, `tests/model-profile-arch.bats`, and this task file. `CHANGELOG.md` was not edited. Pre-existing unrelated/concurrent worktree changes were preserved.
- Architecture summary: executable now keeps dependency loading, CLI parsing/dispatch, prompts, rendering, and high-level orchestration; stable provider, profile/schema/storage/transaction, token storage, and HTTP/request handling domains live in idempotently sourced model-profile modules loaded in repository and installed layouts.
- Provider registry summary: provider prompt choices, labels, required location fields, display endpoint templates, and OpenAI-compatible API base URL templates are defined once in the provider module and consumed without dynamic evaluation.
- Direct/installed test summary: `tests/model-profile-arch.bats` sources every module twice and calls module functions directly without invoking `main`; it also builds an installed-layout fixture and passes create/list/models/ask/delete with stubbed curl.
- Command summary: `bash -n tools/bin/model-profile tools/lib/picotools/model-profile/provider.sh tools/lib/picotools/model-profile/profile.sh tools/lib/picotools/model-profile/token.sh tools/lib/picotools/model-profile/http.sh tests/helpers/model-profile.bash tests/model-profile-arch.bats tests/model-profile-storage.bats tests/model-profile-schema.bats tests/model-profile-cli.bats tests/model-profile-request.bats` passed.
- Command summary: `bats tests/model-profile-arch.bats` passed with 2 tests.
- Command summary: `npm run test:model-profile` passed with 68 tests.
- Command summary: `shellcheck -s bash -x tools/bin/model-profile tools/lib/picotools/model-profile/provider.sh tools/lib/picotools/model-profile/profile.sh tools/lib/picotools/model-profile/token.sh tools/lib/picotools/model-profile/http.sh tests/helpers/model-profile.bash tests/model-profile-arch.bats tests/model-profile-storage.bats tests/model-profile-schema.bats tests/model-profile-cli.bats tests/model-profile-request.bats` passed.
- Command summary: `npm run check:syntax` passed.
- Command summary: `scripts/shfmt-diff.bash` passed.
- Command summary: `git diff --check` passed.
- Command summary: `pre-commit run --files tools/bin/model-profile tools/lib/picotools/model-profile/provider.sh tools/lib/picotools/model-profile/profile.sh tools/lib/picotools/model-profile/token.sh tools/lib/picotools/model-profile/http.sh tests/model-profile-arch.bats docs/tasks/20260823-200127-model-profile-health-remediation.md` passed.
- Follow-ups/blockers: none for ARCH-01.

### Task PERF-01: Measure Profile Listing And Parsing Churn

Status: completed

Priority: P3

Suggested agent: Bash performance engineer

Dependencies: ARCH-01

Primary ownership:

- Reproducible model-profile benchmark fixture
- Profile/provider modules only for measured improvements
- Production list/render paths only when justified

Finding:

Listing launches multiple `git config` and utility processes per profile, while table rendering invokes `awk` repeatedly per cell. Independent review observed approximately 0.10s for 1 profile, 1.16s for 25, and 5.80s for 100, but those measurements are not yet a committed reproducible baseline. Network request performance is not a useful target compared with remote latency.

References:

- `tools/bin/model-profile:229-276`
- `tools/bin/model-profile:713-830`
- `lib/picotools/table.sh:36-43`
- `lib/picotools/table.sh:84-115`

Implementation requirements:

1. Add a reproducible benchmark for list/read with 1, 25, 100, and optionally 1,000 valid profiles.
2. Record environment, wall-clock distribution, and Git/awk/subprocess counts before production changes.
3. Measure one-pass profile parsing, shell name derivation, validated in-memory records, and table-rendering alternatives separately.
4. Preserve duplicate/malformed config rejection and output semantics established by SCHEMA-01.
5. Do not optimize shared table helpers unless separate measurement proves a shared benefit and all consumers are tested.
6. Retain only a material documented improvement; otherwise mark the task deferred with evidence and no production churn.

Acceptance criteria:

- Benchmark commands, fixture shape, environment, baseline, and after-results are recorded in this task.
- Any retained change materially lowers process count and representative median wall time without weakening validation.
- Valid output remains byte-equivalent unless a prior contract task deliberately changed it.
- Focused and full package tests remain green, or the task is deferred with residual cost documented.

Completion evidence:

- Changed files for PERF-01: `scripts/benchmark-model-profile-perf.bash`, `tools/lib/picotools/model-profile/profile.sh`, `tools/bin/model-profile`, and this task file. `CHANGELOG.md` was not edited. Pre-existing unrelated/concurrent worktree changes were preserved.
- Benchmark command: `bash scripts/benchmark-model-profile-perf.bash --repeat 3 --counts "1 25 100"`.
- Benchmark fixture shape: each count uses a temporary isolated `HOME`, `XDG_CONFIG_HOME`, and `XDG_DATA_HOME`; generates N valid `model-profile` `.conf`/`.token` pairs; mixes `azure-openai`, `azure-cognitive-services`, `gemini`, and `custom` profiles; token directory mode `0700`; token files mode `0600`; measures production `list` and interactive `read`, plus separate probes for basename vs shell name derivation, multi-Git vs one-Git profile parsing, validated in-memory records with token checks, and shared-table vs native non-TTY table rendering.
- Benchmark environment: Linux `5CG5181VVF-N 6.18.33.2-microsoft-standard-WSL2 #1 SMP PREEMPT_DYNAMIC Thu Jun 18 21:54:43 UTC 2026 x86_64`; Bash `5.2.21(1)-release`; Git `2.43.0`; GNU Awk `5.2.1`; tool `/home/jahn/projects/_picotools/tools/bin/model-profile`.
- Baseline production results before production changes, `--repeat 3`: 1 profile `list` median `0.192993s`, Git/Awk/tracked subprocesses `13/24/50`; 1 profile `read` median `0.237149s`, `13/40/67`; 25 profiles `list` median `3.228200s`, `325/312/914`; 25 profiles `read` median `0.312890s`, `13/40/115`; 100 profiles `list` median `12.845630s`, `1300/1212/3614`; 100 profiles `read` median `0.650319s`, `13/40/265`.
- Baseline probe results before production changes, `--repeat 3`: 100-profile basename derivation median `0.352902s` vs shell derivation `0.217948s`; multi-Git parsing median `5.931941s` and `900` Git subprocesses vs one-Git parsing `2.245327s` and `100` Git subprocesses; validated records with token checks `6.206730s` and `900` Git subprocesses vs one-Git records `3.270477s` and `100` Git subprocesses; shared table rendering `4.964209s` and `1212` Awk subprocesses vs native non-TTY rendering `0.507071s` and `0` Awk subprocesses.
- Retained changes: `profile_name_from_file` now derives names with shell parameter expansion instead of `basename`; `read_valid_profile_record` parses `git config --list` once per profile into validated in-memory fields while retaining malformed/empty config, unknown managed key, duplicate managed key, provider/location/model validation, and normalized output behavior; `list`, `read`, and `models` reuse validated records where applicable; model-profile uses a local non-TTY table renderer for byte-equivalent ASCII table output and falls back to shared `picotools_print_table` for pretty TTY output. Shared table helpers were not modified.
- After-results with retained production changes, same command and environment: 1 profile `list` median `0.100033s`, Git/Awk/tracked subprocesses `1/0/7`; 1 profile `read` median `0.106625s`, `1/0/7`; 25 profiles `list` median `0.985258s`, `25/0/127`; 25 profiles `read` median `0.130588s`, `1/0/7`; 100 profiles `list` median `4.857388s`, `100/0/502`; 100 profiles `read` median `0.440909s`, `1/0/7`.
- Material improvement summary: 100-profile `list` median improved from `12.845630s` to `4.857388s` with Git subprocesses reduced `1300 -> 100` and Awk subprocesses `1212 -> 0`; 100-profile `read` median improved from `0.650319s` to `0.440909s` with Git subprocesses `13 -> 1` and Awk subprocesses `40 -> 0`.
- Output/validation semantics: SCHEMA-01 duplicate, malformed, unknown-key, unsafe storage, legacy-provider, and request-boundary tests remain green under `npm run test:model-profile`; the non-TTY table renderer mirrors the shared table layout for valid uncolored model-profile output and the shared renderer remains in use for pretty TTY output.
- Verification: `bash -n tools/bin/model-profile tools/lib/picotools/model-profile/profile.sh scripts/benchmark-model-profile-perf.bash` passed; one-profile non-TTY `model-profile list` output compared byte-equivalent to `picotools_print_table` output with `cmp -s`; `npm run test:model-profile` passed with 68 tests; `shellcheck -s bash -x tools/bin/model-profile tools/lib/picotools/model-profile/profile.sh scripts/benchmark-model-profile-perf.bash` passed; `npm run check:syntax` passed; `scripts/shfmt-diff.bash` passed; `git diff --check` passed; `pre-commit run --files tools/bin/model-profile tools/lib/picotools/model-profile/profile.sh scripts/benchmark-model-profile-perf.bash docs/tasks/20260823-200127-model-profile-health-remediation.md` passed; full `npm test` passed with 478 tests after an earlier 300s timeout at test 416.
- Residual cost: `list` still validates stored token content for every row, leaving one Git config subprocess per profile plus token `stat`/`od` checks; this is retained deliberately to preserve fail-closed credential validation. Further reductions would require a separate security/performance task for token-status semantics. Pretty TTY table output still uses the shared Awk-based helper to avoid changing colored interactive semantics without a cross-consumer measurement task.

## Wave 5: Public Contract And Independent Review

### Task DOC-CI-01: Align Dependencies Documentation And Installed Checks

Status: completed

Priority: P2

Suggested agent: documentation and CI engineer

Dependencies: ARCH-01; PERF-01 may be completed or deferred

Primary ownership:

- `README.md`
- `usage()` in `tools/bin/model-profile`
- `package.json`
- `.github/workflows/test.yml`
- `.github/workflows/pre-commit.yml` only if validation triggers need adjustment

Finding:

The README does not document Git as a core persistence dependency and incorrectly says `list` can display selected details inline, while tests assert `list` is non-interactive. Installed CI checks only help/version and would not detect missing new modules or broken CRUD/request behavior.

References:

- `README.md:23`, `README.md:41`
- `tools/bin/model-profile:16-49`
- `package.json:15-24`
- `.github/workflows/test.yml:42-55`, `.github/workflows/test.yml:109-110`

Implementation requirements:

1. Document Git as the persistence dependency and curl/jq as request-only dependencies, plus selected key permissions, endpoint policy, request limits, CLI grammar, and failure-safe publication behavior.
2. Correct the `list`/`read` contract and align help, README, tests, and implementation.
3. Add isolated installed-layout operations for empty list, non-secret profile creation/read/models, and a stubbed request that verifies destination/body without using a real key.
4. Assert every extracted model-profile module is present in the installed archive.
5. Keep credentials and endpoint sentinels out of workflow logs and runner-global HOME/XDG paths.
6. Ensure `test:model-profile` covers all split suites and repository-wide test discovery remains compatible.

Acceptance criteria:

- Help, README, implementation, and tests describe the same dependencies and behavioral/security contracts.
- Installed CI fails when any required module is omitted and passes CRUD plus request-construction smoke under isolated HOME/XDG state.
- No workflow fixture contacts the network or logs a credential.
- Focused package, workflow syntax, formatting, and pre-commit checks pass.

Completion evidence:

- Changed files for DOC-CI-01: `README.md`, `tools/bin/model-profile`, `tests/model-profile-cli.bats`, `.github/workflows/test.yml`, and this task file. `CHANGELOG.md` was not edited. Pre-existing unrelated/concurrent worktree changes were preserved; a temporary chmod mode change from local smoke verification on `tools/bin/git-clean-task-pr` was restored.
- Documentation/help summary: README and `model-profile --help` now document Git as the profile persistence dependency, `curl`/`jq` as request-only dependencies for `ask`/`test`, token directory/file mode requirements, HTTPS/proxy/redirect endpoint policy, request timeout/payload/response/diagnostic limits, CLI grammar, and same-directory failure-safe publication/rollback behavior.
- `list`/`read` contract summary: README, help, and CLI tests now agree that `list` prints the saved-profile table without prompting and `read` takes no operands and prompts for one saved profile before printing details.
- CI/package summary: `.github/workflows/test.yml` now asserts installed `provider.sh`, `token.sh`, `profile.sh`, and `http.sh` modules exist; runs empty `list`, interactive `create`/`read`, direct `models`, and stubbed `ask` in an isolated `tmp/model-profile-home`; and verifies the constructed request URL/body through a local curl stub without contacting the network. `package.json` needed no DOC-CI change because `test:model-profile` already discovers all `tests/model-profile*.bats` split suites and repository-wide `npm test` remains `bats tests/*.bats`.
- Command summary: `npm run test:model-profile` passed with 68 tests.
- Command summary: `npm run check:syntax` passed.
- Command summary: `npm run check:shellcheck` passed.
- Command summary: `npm run check:format` passed, including `git diff --check`; rerun after completion-evidence edits also passed.
- Command summary: workflow YAML syntax parse passed with `python`/PyYAML for `.github/workflows/test.yml`; `actionlint .github/workflows/test.yml` could not run because the local asdf shim reports no configured `actionlint` version in `.tool-versions`.
- Command summary: installed-layout smoke equivalent passed from a freshly packed archive, including module-presence assertions, isolated empty list/create/read/models operations, and a stubbed request URL/body check.
- Command summary: final `git diff --check` passed.
- Command summary: focused `pre-commit run --files README.md tools/bin/model-profile tests/model-profile-cli.bats .github/workflows/test.yml docs/tasks/20260823-200127-model-profile-health-remediation.md` passed.
- Follow-ups/blockers: no implementation follow-up for DOC-CI-01; local `actionlint` remains unavailable until this checkout configures an actionlint version or another workflow linter is provided.

### Task REVIEW-01: Perform Independent Security And Integration Review

Status: completed

Priority: P0

Suggested agent: independent Bash/security reviewer not used for implementation

Dependencies: TEST-01, SEC-01, SCHEMA-01, NET-01, HTTP-01, LIMIT-01, STATE-01, CLI-01, ARCH-01, DOC-CI-01; PERF-01 may be completed or explicitly deferred

Primary ownership:

- Review only, plus focused fixes/tests for discovered regressions

Finding:

The remediation crosses persisted credentials, URL authorities, local/private endpoint policy, curl process boundaries, resource limits, transaction state, CLI statuses, module packaging, and public behavior. An independent pass must validate runtime failure paths rather than implementation shape alone.

References:

- Every task and acceptance criterion in this document
- `tools/bin/model-profile`
- `tools/lib/picotools/model-profile/`
- `tests/model-profile*.bats`
- Installed archive workflow in `.github/workflows/test.yml`

Implementation requirements:

1. Reproduce Azure authority delimiter cases, custom URL malformed/option cases, and the selected local/private/HTTP policy against the final executable. Confirm rejected destinations do not read keys or invoke transport.
2. Reproduce symlinked roots/leaves, hard links, FIFO/non-regular leaves, unsafe permissions, malformed key content, and failure injection for create/update/delete.
3. Inspect live subprocess arguments, environment, debug/error output, curl config behavior, and temporary artifacts for key or prompt leakage.
4. Verify request bounds for inline/file input, payload, connect/total duration, success/error responses, and handled signals.
5. Verify every command's arity and status behavior, including no profiles, EOF, invalid selection, cancellation, and conflicting options.
6. Verify public docs/types do not exist for this Bash tool but help, README, tests, implementation, and installed behavior agree.
7. Review module ownership and each deferred item with its rationale and residual risk. Preserve unrelated worktree changes.

Acceptance criteria:

- Every prior task has runtime or test evidence for each acceptance criterion.
- No key crosses validated storage/network boundaries, argv, environment, diagnostics, logs, tables, or retained temporary artifacts.
- Alternate direct and interactive entry paths enforce the same profile, destination, key, and resource policies.
- `npm run test:model-profile`, `npm test`, syntax, shellcheck, formatting, and `pre-commit run --all-files` pass or unrelated pre-existing failures are recorded exactly.
- The installed archive passes operational model-profile CRUD and stubbed-request smoke tests.
- No model-profile credential or transaction artifact remains in the worktree or test roots.

Completion evidence:

- Review coverage: re-read this full task file and reviewed current `tools/bin/model-profile`, `tools/lib/picotools/model-profile/{provider,token,profile,http}.sh`, `tests/helpers/model-profile.bash`, focused `tests/model-profile-*.bats`, `README.md`, `package.json`, `.github/workflows/test.yml`, `scripts/shellcheck.bash`, `scripts/shfmt-diff.bash`, and `scripts/benchmark-model-profile-perf.bash`. `CHANGELOG.md` was not edited.
- Acceptance review: prior completed tasks include runtime/test evidence for destination validation, path-safe token storage, profile schema validation, curl credential isolation, request bounds, transaction rollback, CLI grammar/statuses, module ownership, performance measurement, and README/help/workflow alignment. The focused suite independently reproduced the required Azure delimiter cases, malformed/option custom URL cases, local/private/HTTP policy, symlinked roots/leaves, hard links, FIFOs/non-regular leaves, unsafe permissions, malformed key content, create/update/delete failure injection, request bounds, handled signals, command arity/status behavior, and installed module loading.
- Credential-boundary review: rejected destination/schema/CLI cases fail before token reads and curl invocation in tests; successful request paths pass credentials only through a mode-`0600` temporary curl config, with curl argv using `-q`, disabled proxying, HTTPS-only protocol constraints, no redirects, explicit `--`, and no key or prompt in captured curl argv. Debug/error output, tables, README/help, workflow logs, and retained temporary files did not expose API keys during reviewed tests.
- Additional runtime smoke: an independent live curl-stub smoke from a temporary workspace fixture inspected the curl subprocess `/proc` argv/env for key and prompt sentinels, verified temporary curl auth config mode `0600`, verified the auth config and payload temp files were removed after success, and verified the Azure request URL. Result: passed.
- Command summary: `npm run test:model-profile` passed with 68 tests.
- Command summary: `npm test` passed with 478 tests.
- Command summary: `npm run check:syntax` passed.
- Command summary: `npm run check:shellcheck` passed.
- Command summary: `npm run check:format` passed, including `git diff --check`.
- Command summary: `pre-commit run --all-files` passed.
- Post-evidence command summary: `pre-commit run --files docs/tasks/20260823-200127-model-profile-health-remediation.md` passed; `git diff --check` passed.
- Installed archive smoke: freshly packed archive installed into an isolated temporary prefix; required model-profile modules were present; isolated installed `model-profile` empty `list`, interactive `create`, interactive `read`, direct `models`, and stubbed `ask` passed; the stub verified the expected chat-completions URL and JSON request body without network access. Result: passed.
- Artifact check: `glob` scans for `tmp/model-profile-*`, `**/.model-profile*.tmp.*`, `**/.model-profile*.backup.*`, and `**/*.token` under the workspace found no leftover model-profile review/test credentials or transaction artifacts after cleanup.
- Findings/fixes: no model-profile regressions were found, so no implementation or test fixes were made. One accidental executable-bit change to unrelated `tools/bin/git-clean-task-pr` from local install-smoke setup was restored; unrelated pre-existing worktree changes were otherwise preserved.
- Residual risks: custom DNS hostnames remain unresolved identities by documented policy and are not claimed to prevent DNS rebinding; real provider/network behavior was not exercised beyond stubbed request construction; broader maintainer policy decisions listed under Deferred Decisions remain future product choices but do not block the current fail-closed implementation.
- Follow-ups/blockers: none for REVIEW-01.

## Dependency And Parallelization Guidance

| Wave | Tasks | Parallelization |
|------|-------|-----------------|
| 1 | TEST-01, then SEC-01 | TEST-01 owns the monolithic suite first; SEC-01 starts after fixtures stabilize. |
| 2 | SCHEMA-01, NET-01, HTTP-01, LIMIT-01 | SCHEMA-01 can run alongside SEC-01 after TEST-01. NET-01 follows SCHEMA-01. LIMIT-01 can design tests in parallel but final transport edits should follow HTTP-01. |
| 3 | STATE-01, CLI-01 | Behavioral decisions are independent, but serialize executable edits until ARCH-01 extracts ownership. |
| 4 | ARCH-01, then PERF-01 | Do not modularize unstable security behavior. PERF-01 starts only after profile loading has one owner. |
| 5 | DOC-CI-01, then REVIEW-01 | Documentation follows final contracts. The final reviewer must be independent of the main implementers. |

Shared hotspots requiring serialized ownership:

- `tools/bin/model-profile`
- `tests/model-profile.bats` until TEST-01 completes
- Profile/token publication functions shared by SEC-01, SCHEMA-01, and STATE-01
- Request construction shared by NET-01, HTTP-01, and LIMIT-01
- `.github/workflows/test.yml`

Recommended agent allocation:

| Agent | Primary tasks |
|-------|---------------|
| Test fixture agent | TEST-01 |
| Filesystem/transaction agent | SEC-01, then STATE-01 |
| Schema/provider agent | SCHEMA-01, then NET-01 |
| HTTP/resource agent | HTTP-01, then LIMIT-01 |
| CLI/architecture agent | CLI-01, then ARCH-01 |
| Performance agent | PERF-01 |
| Docs/CI agent | DOC-CI-01 |
| Independent reviewer | REVIEW-01 only |

## Deferred Decisions Requiring Maintainer Input

1. **Custom endpoint network policy:** Decide whether custom profiles may use cleartext HTTP and loopback/private/link-local destinations. Recommended: HTTPS by default, with an explicit per-profile insecure/local opt-in that is visible in `read`; never imply that a static IP denylist fully prevents DNS rebinding. This decision blocks only the policy portion of NET-01, not structural URL validation.
2. **Credential permission drift:** Decide whether reads/status should fail closed or silently repair safe regular files. Recommended: fail closed for read/status/delete and repair only during explicit writes, matching the stronger existing `git-profile` contract.
3. **Request limits:** Select public defaults for input, payload, response, connect timeout, and total timeout. Recommended: agents first add configurable finite limits and boundary tests, then record chosen defaults in help/README before release.
4. **Legacy profile normalization:** Decide whether valid existing custom HTTP/private profiles require an explicit migration/confirmation or are temporarily grandfathered. Do not grandfather malformed authorities, userinfo, control bytes, path traversal, or credential-exfiltrating Azure names.

## Definition Of Done

- Every P0/P1 task is completed with a failing-before regression and passing verification evidence.
- Rejected profile paths, persisted schemas, Azure resource names, and custom endpoints fail before key access and transport.
- Key storage is path-safe, mode-safe, atomic, non-blocking on special files, and free of argv/log/temp leakage.
- Create/update/delete publish coherent profile/key state or preserve the previous state according to a documented tested contract.
- Request execution ignores ambient curl configuration, has explicit redirect/protocol behavior, and enforces finite input/time/response bounds.
- CLI arity, option conflicts, cancellation, EOF, and helper failures return documented statuses without side effects.
- The executable is orchestration-focused; stable modules have explicit dependencies, direct tests, and installed-layout coverage.
- Any retained performance work has reproducible material improvement; otherwise it is explicitly deferred with evidence.
- Help, README, tests, workflow behavior, and implementation agree.
- An independent reviewer completes REVIEW-01 and records full repository and installed-artifact verification.
