# Add k8s-profile Namespace Support

Created: 2026-11-13 10:26:17 (local time)

## Objective And Scope

Implement the user-authorized follow-up that gives every
[k8s-profile](20261112-141439-add-k8s-profile.md) profile an explicit
Kubernetes namespace. Motivation: a profile without `context.namespace`
silently resolves to the `default` namespace after `k8s-profile use`,
which produces confusing server-side RBAC failures for accounts scoped
to a single namespace. Namespace options were explicitly deferred in the
original plan; this phase adds them without changing `use` semantics,
deletion cleanup, or the transaction engine.

### Task NS-01: Explicit Namespace On Create, Update, And List

Status: completed

Kind: improvement

Priority: P1 — removes the silent `default`-namespace fallback footgun.

Dependencies: original plan (K8S-01..K8S-05) and the switching follow-up
(USE-01), both completed.

Primary ownership:

- `tools/lib/picotools/k8s-profile/{model,lifecycle,actions,config,common}.sh`,
  `tools/bin/k8s-profile` help text.
- `tests/k8s-profile-namespace.bats` (new), existing create/update/list/tty
  tests, `tests/helpers/k8s-profile.bash`, installed smoke.
- `README.md` and this task document.

Requirements (user-confirmed design):

1. Create always prompts for Namespace with `default` as the shown safe
   default; Enter accepts it explicitly. Values must be valid DNS-1123
   labels (lowercase alphanumeric and `-`, <= 63 chars). Validation is
   offline only; no cluster request validates the namespace exists.
2. Update gains a `Namespace [<current>]` entry in the field menu
   (Server / Token / Namespace / Done). Only a valid existing namespace
   is usable as the prompt default (same policy as the Server default).
   Entering a different valid namespace changes it; blank keeps the
   shown default. Update never clears a namespace.
3. List gains a Namespace column showing `-` for contexts without one,
   including external contexts, with exact display escaping.
4. Namespace changes reuse `plan_change`/`stage_change`/`verify_change`
   with a namespace-aware plan and merged-view verification; unchanged
   namespace stays byte-identical, including unset.
5. `use`, delete, and all path/lock/stale-state safety behavior remain
   unchanged. No network calls, no credential exposure; all tests stay
   isolated (synthetic HOME/KUBECONFIG/XDG/TMPDIR).

Acceptance criteria:

- Create stores the chosen/default namespace; update edits it only when
  selected; unchanged edits remain no-ops; list shows the column with
  `-` for unset and escaped external values.
- Invalid namespace inputs (uppercase, underscores, spaces, controls,
  too long, empty without a usable default) are refused before staging.
- Installed smoke covers the extra prompt and the shifted Done index.
- Focused/full tests, package gates, direct ShellCheck/shfmt, pre-commit
  (explicit files and all-files), and installed smoke pass.

Definition of done: all acceptance criteria verified, evidence recorded,
and NS-01 completed. Hosted CI is not claimed by local verification.

## Implementation

- `common.sh`: new `k8s_profile_validate_namespace` enforcing the exact
  DNS-1123 label policy (`^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$`),
  offline only, with a `DNS-1123 label` diagnostic.
- `actions.sh`: create prompts `Namespace [default]: ` after Token via
  `k8s_profile_prompt_required` (Enter accepts the shown default; blank
  without a usable default is refused; EOF fails) and passes
  `plan_change "$name" "$server" true true "$namespace" true`.
- `lifecycle.sh`: update field menu is now `1=Server, 2=Token,
  3=Namespace, 4=Done` (default `[4]`); namespace default shows only
  when the stored value is valid; entering the unchanged value is a
  byte-preserving no-op (`namespace_change=false`); update never clears
  a namespace. Summaries print `Namespace: <value> (set|unchanged)`.
- `model.sh`: `plan_change` gained `[namespace] [namespace_change]`
  arguments, plans carry `namespace_change` + `expected_namespace`, and
  the merged `verify_change` asserts
  `(.context.namespace // "") == expected_namespace`.
- `config.sh`: projection adds `namespace: (.context.namespace // "")`
  and the list table gains a Namespace column (`-` for unset, exact
  display escaping for external values).
- `tools/bin/k8s-profile`: help text mentions the Namespace prompt and
  update entry.
- `scripts/functional-test-k8s-profile-install.bash`: smoke answers
  `ai-poc` for the create Namespace prompt and `3\npoc-deploy\n4\n` in
  the update menu; asserts `.contexts[0].context.namespace`.
- Tests: new `tests/k8s-profile-namespace.bats` (12 tests); existing
  create/update/review/lifecycle-transaction/security/tty tests updated
  for the shifted Done index and the extra prompt; helpers gained a
  namespace argument on `create_profile`/`update_profile` (Done = 4).

## Verification Evidence

- Focused k8s-profile suite: 248/248 ok, 0 failures, exit 0
  (`npm run test:k8s-profile`, pinned bats/shellcheck/shfmt toolchain).
  An earlier run appeared as "244 ok" because four regressions were
  hidden behind the ok count; those are fixed and covered below.
- New `tests/k8s-profile-namespace.bats`: 12/12 ok, including validator
  unit test, create default/custom/invalid/EOF paths, update menu order
  `[4]`, set/keep/no-op/never-clear/invalid-default policy, and the list
  column with `-`, `ai-poc`, `kept`, and escaped `ns\u007cd\u007f`.
- Overwrite namespace policy: the create Namespace prompt defaults to
  the profile's existing valid namespace (`k8s_profile_update_namespace_default`)
  when overwriting, falling back to the literal `default` for fresh or
  unset/invalid namespaces. A blank answer therefore can never silently
  clear a namespace on overwrite — matching "reuses explicit ownership
  and preserves context fields" expectations in
  `tests/k8s-profile-create.bats` (fixtures keep `namespace: "kept"`).
- `tests/k8s-profile-review.bats`: the inherited-allexport create test
  needed a fourth input line (blank accepting the shown namespace
  default) since it predates the Namespace prompt.
- Package gates: `check:syntax`, `check:shellcheck`, `check:format` all
  pass (SC2034 unused `valid` removed from the new bats file).
- Direct ShellCheck and `shfmt --diff --indent 2` pass on all changed
  k8s-profile modules, the launcher, the test helper, and the install
  smoke script.
- pre-commit (pinned toolchain): `--files` on all changed files and
  `--all-files` both pass every hook with no modifications.
- Installed smoke: the archive release test in the focused suite passes
  with the namespace interactions included.
- Full `npm test` (735 tests): one earlier run hung for 45+ minutes on
  the pre-existing pty race in `tests/prompt.bats`
  ("interactive secret prompt handles backspace while updating mask",
  `script -qec` stdin/pty handshake); that test passes in isolation and
  in file context and is unrelated to namespace changes. The complete
  rerun passes: 735/735 ok, 0 failures, exit 0 (under 90 minutes, with
  a `timeout` guard in place against the flaky hang).
- pre-commit `--all-files` re-run after the overwrite-default fix and
  the review test input fix: every hook passes, no modifications.
