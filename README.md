# picotools

A collection of installable bash scripts bundled as a release repository, with support for [asdf](https://github.com/asdf-vm/asdf) plugin-based installation.

## Tools

The following scripts are included in `tools/bin`:

| Tool | Description |
|------|-------------|
| `asdf-install` | Installs all tools defined in `.tool-versions` via asdf |
| `asdf-cli-install` | Lists recent asdf-vm/asdf GitHub releases, marks the current asdf CLI version, and installs the selected version |
| `asdf-upgrade` | Finds newer stable strict-semver asdf versions and updates selected `.tool-versions` entries |
| `asdf-clean-unused` | Scans workspace `.tool-versions` files and removes unused asdf plugins or versions |
| `pip-upgrade` | Updates exact requirement pins in `requirements.txt` within a selected version scope |
| `npm-publish-package` | Bundles a package, rewrites publish metadata, and publishes one or more package names from a publish directory |
| `oc-route` | Lists, reads, and interactively applies OpenShift route manifests |
| `oc-quota-requests` | Analyzes OpenShift namespace CPU and memory request quota usage |
| `gh-repo-sync` | Downloads and caches all repos for a GitHub user/org |
| `gh-actions-upgrade` | Updates pinned GitHub Action refs under `.github` to the latest tag or tag commit hash |
| `gh-release-assets` | Exports each GitHub repo release with its name, published_at, and asset-name list to a JSON file |
| `pre-commit-upgrade` | Runs `pre-commit autoupdate` against a pre-commit config file |
| `model-profile` | Stores named model provider profiles with config and token data kept separately |
| `git-profile` | Stores named Git identity profiles and optional GitHub PATs with repository-local selection |
| `git-commit` | Uses a configured model provider to propose and create conventional commits from workspace changes |
| `git-api` | Calls GitHub REST operations by `operationId` using split OpenAPI method files |
| `git-release-setup` | Generates a release SSH keypair, stores it as an Actions secret, and configures matching deploy-key permissions |
| `git-clean-branches` | Force-deletes local branches and deletes merged remote branches except protected branches |
| `git-clean-task-pr` | Creates a fresh PR branch by pulling the base branch, then soft-resetting to one staged commit |
| `license` | Creates or updates a LICENSE file from MIT or Apache 2.0 templates |
| `inotify-watches` | Reports per-PID Linux inotify watch usage against `fs.inotify.max_user_watches` |

`gh-repo-sync` requires `curl`, `jq`, and `unzip` to be available on the system.

`gh-actions-upgrade` scans `.github/**/*.yml` and `.github/**/*.yaml` by default, updates `uses: owner/repo@ref` entries to each action repository's latest tag, prefers stable version tags over prereleases when both exist, and preserves each ref's current style unless `--ref-type tag` or `--ref-type hash` is used to force all rewritten refs to one form. It ignores local `./...` actions and `docker://...` references, requires `git` plus `sort`, and uses `GH_TOKEN`, `GITHUB_TOKEN`, `GITHUB_PAT`, or `PAT_TOKEN` for authenticated lookups when private action repositories need access.

`gh-release-assets` iterates all releases of a GitHub repository through `git-api` and writes a JSON file in the caller's current directory listing each release's `name`, `published_at`, and `assets` array of asset-name strings. It pages through `repos/list-releases` up to `--max-releases` (default 100), writes the default file as `<owner>-<repo>-releases.json`, and accepts `--output PATH` to override the destination. Pass `owner` and `repo` as positional arguments or omit them to be prompted interactively. It requires `git-api` and `jq`, and uses the same authentication as `git-api`. Use `--debug` for progress details on stderr.

`pre-commit-upgrade` runs `pre-commit autoupdate` against `.pre-commit-config.yaml` by default. It preserves each repo's current ref style unless `--ref-type tag` or `--ref-type hash` is used to force all rewritten refs to one form, and `--config PATH` targets a different config file. It requires `pre-commit` to be installed.

`model-profile` stores provider metadata under `${XDG_CONFIG_HOME:-$HOME/.config}/model-profile` and tokens under `${XDG_DATA_HOME:-$HOME/.local/share}/model-profile`. Git is required for profile persistence commands; `curl` and `jq` are required only by request commands (`ask` and `test`). Token reads and status checks fail closed unless the token directory is mode `0700` and token files are mode `0600`; explicit token writes repair safe regular-file paths and `create`, `update`, and `delete` stage complete validated state before same-directory atomic publication and roll back on token/profile failures. It supports `azure-openai`, `azure-cognitive-services`, `gemini`, and `custom` profiles with `create`, `update`, `list`, `read`, `profiles`, `models`, `ask`, `test`, and `delete`. Azure providers store a DNS-compatible lowercase resource label, while `custom` stores an explicit OpenAI-compatible HTTPS endpoint URL. Custom endpoints must use `https://` with a DNS hostname or public IPv4 literal; userinfo, fragments, query strings, HTTP, localhost, private, loopback, and link-local address literals are rejected before API keys are read. Hostnames are treated as unresolved identities rather than proof that a destination is public. `list` prints the saved-profile table and never prompts for a selected profile; `read` takes no operands and prompts for one saved profile before showing details. Global `--debug` is accepted before or immediately after a command, `--` ends option parsing for operands, no-operand commands reject operands, `models` requires exactly one profile operand, and non-interactive `ask` requires exactly one profile plus one user message source (`--message`, `--user-message`, `--message-file`, or `--user-message-file`). `ask` uses OpenAI-compatible `chat/completions` requests. Use `model-profile ask <profile> --message TEXT` to send a prompt, `--message-file PATH` for larger prompts, `--model MODEL` to override the default first configured model, and `--system-message TEXT` or `--system-message-file PATH` to override the default system prompt. Message-file paths must be readable regular files; symlinks, FIFOs, devices, and other special files are rejected before request construction. `--user-message` is accepted as an alias for `--message`. Use `--debug` to print request-phase steps to stderr. `MODEL_PROFILE_DEBUG=true` still works as a deprecated fallback. Requests ignore `.curlrc`, do not use proxies, use HTTPS only, and do not follow redirects. Request limits have finite defaults and positive bounded overrides: `MODEL_PROFILE_CURL_CONNECT_TIMEOUT` defaults to 10 seconds and allows up to 120, `MODEL_PROFILE_CURL_MAX_TIME` defaults to 60 seconds and allows up to 600, `MODEL_PROFILE_MAX_PAYLOAD_BYTES` defaults to 1048576 bytes and allows up to 10485760, `MODEL_PROFILE_MAX_RESPONSE_BYTES` defaults to 1048576 bytes and allows up to 10485760, and `MODEL_PROFILE_MAX_DIAGNOSTIC_BYTES` defaults to 4096 bytes and allows up to 65536.

`git-profile` stores named Git identity profiles and optional GitHub PATs. `git` is required for operational commands, while `--help` and `--version` do not require optional key-management tools. `ssh-keygen` is required only when generating a new SSH key. The configured GPG command, `gpg` by default, is required only when generating a signing key or deleting GPG material.

`git-profile` stores non-secret Git identity/config metadata under `${XDG_CONFIG_HOME:-$HOME/.config}/git-profile/<name>.gitconfig` and each optional GitHub PAT separately under `${XDG_DATA_HOME:-$HOME/.local/share}/git-profile/<name>.token`. Saved profile files are tool-owned and reconstructed by `create`/`update`, so unmanaged keys and comments in those files are not preserved. The data directory is enforced to mode `0700` and PAT files to `0600`; this is filesystem-permission protection, not encryption. PAT reads and status checks fail closed when those permissions drift, while explicit PAT writes repair safe regular-file paths. PAT writes are single-line only and are staged in the same directory before atomic replacement.

`git-profile create`, `list`, `commands`, `delete`, `set`, and `update` accept no command-specific arguments. `git-profile read` accepts only `--commands`. `--debug` is global-only and must appear before the command. `git-profile clone` supports an interactive form, `git-profile clone <profile> <url>`, or `git-profile clone <profile> --url <url>`. Create/update build a complete validated profile candidate before publishing it; token failures roll back profile changes, and delete preflights owned profile/PAT state before removing optional SSH or GPG material.

`git-profile set` applies the selected saved profile to the current repository and records the active profile name in local Git config as `picotools.gitProfile`. `git-profile clone <profile> <url>` does the same while cloning. New SSH profiles persist a structured `picotools.sshKeyPath` and derive `core.sshCommand` from it; existing profiles remain compatible only when their legacy `core.sshCommand` matches the command form emitted by `git-profile`. `git-profile token` resolves the repository-local marker and prints only the active profile PAT to stdout, so use it only in trusted pipelines or command substitution. `list` and `read` show only whether a PAT is configured and never print token bytes.

`git-commit` stores its selected model profile and model under `~/.config/git-commit/config`. Run `git-commit configure` first; if `git-api` named PAT profiles are present, it will also offer an optional `git-api` profile selection to use as the pull-request fallback profile. Then run `git-commit` inside a Git repository to ask the configured model for a conventional-commit plan and print shell-escaped `git add` and `git commit -m ...` commands for one or more commits from the current workspace changes. Planned `files` coverage is strict even for a single commit, and commit messages must start with an imperative lower-case verb. If staged changes already exist, it can optionally unstage them with `git restore --staged :/` before generating the preview. In monorepos, derived scopes prefer the leaf package name instead of repeating the npm org prefix. Use repeatable `--path PATH` flags to limit planning, staging, and commits to selected files or directories without touching unrelated workspace changes, or `--path-file PATH` to load one scoped path per line from a file. Use `--debug` to print progress steps to stderr, `--apply` to create the planned commits, `--push` to imply `--apply` and push them afterward, and `--pr` to imply `--apply --push` and open or update a pull request through `git-api`. Preview mode does not execute repository-controlled hooks. Apply mode may execute the repository's `pre-commit` hook as a preliminary check from the repository root with a temporary index containing only the selected paths; these hooks are repository-controlled code and should be trusted before running `--apply`. The planned commits are then created through an isolated commit path without invoking Git commit hooks. In `--pr` mode, the model must return both `pull_request.title` and `pull_request.body`. `--pr` accepts an optional base branch; when omitted, `git-commit` resolves the repository default branch through `git-api` and falls back to git remote metadata. Authentication precedence for every `git-api` call in `--pr` mode is: the PAT owned by the repository's `picotools.gitProfile`, then the configured `git-api.profile`, then `git-api`'s existing auth resolution.

### git-commit Configuration

`git-commit configure` writes the primary model profile/model, optional fallback model profile/model, and optional `git-api` profile under `${XDG_CONFIG_HOME:-$HOME/.config}/git-commit/config`. Normal runs require `git`, `jq`, and `model-profile`; `--pr` additionally requires `git-api` and `git-profile` so repository-local PAT precedence can be honored. `--debug` prints progress and bounded model diagnostics, but model responses are redacted, JSON-escaped, and truncated before they are shown.

### git-commit Preview And Apply

The default mode is preview-only: it reads the current repository changes, asks the configured model for a complete plan, validates the plan, and prints shell-escaped `git add` and `git commit -m ...` commands. Preview mode does not stage files, create commits, push branches, open or update pull requests, or execute repository-controlled hooks. It may read repository files and call the configured model provider.

`--apply` first revalidates that the selected workspace still matches the planned snapshot, then creates the planned commits. `--push` implies `--apply` and pushes the current branch after the local commits are created. `--pr` implies `--apply --push` and creates or updates a pull request only after the push succeeds.

### git-commit Scope And Paths

Commit scopes are inferred from the branch and changed files unless `--scope VALUE` or `--no-scope` is supplied. `--path PATH` and `--path-file PATH` limit planning, preliminary hook checks, staging, and commits to selected repository paths. Path files are newline-delimited and are loaded before planning; missing files, unknown options, and missing option values fail before hooks, model calls, staging, commits, pushes, or PR operations.

Repository paths are handled as exact repository-relative names internally and are passed to Git through top-anchored literal pathspecs. Filenames containing spaces, quotes, backslashes, shell metacharacters, glob characters, leading colons, tabs, newlines, and non-ASCII characters are matched literally rather than by Git pathspec expansion.

### git-commit Hooks And Repository Code

Preview mode does not execute repository-controlled hooks. Apply mode may run the repository's executable `pre-commit` hook as a preliminary check from the repository root with a temporary index containing only the selected paths, including deletions. That hook is repository-controlled code and should be trusted before running `--apply`. Out-of-scope worktree mutations from the preliminary hook are rejected. The final planned commits are created through an isolated commit path that does not invoke Git commit hooks.

### git-commit Stale Plans And Recovery

`git-commit` records a fingerprint of the selected path set and content before asking the model for a plan. Before applying, it rejects stale plans when selected files are added, removed, renamed, or modified after planning, or when the real index is not in the expected empty state. Each commit is built from exactly its planned file set so unrelated staged files and later-commit files cannot silently move into the current commit.

If a local commit fails, earlier local commits remain in history and later planned commits are not attempted. If push fails, local commits remain and no PR operation is attempted. If PR creation or update fails after a successful push, the pushed branch remains. The tool prints recovery guidance and does not automatically reset local commits, indexes, worktrees, or remote branches.

### git-commit Push, PR, And Auth

For pull requests, `git-commit` resolves fetch and push topology separately so fork pushes can use a qualified `<owner>:<branch>` head while same-repository pushes keep the branch name. Existing PR lookup failures, malformed API responses, and unresolved repository topology fail before planning, committing, pushing, or creating a new PR.

Pull-request authentication precedence is the PAT owned by the repository's local `picotools.gitProfile` marker, then the configured `git-api.profile` selected by `git-commit configure`, then `git-api` fallback authentication. Repository PAT bytes are passed to `git-api` through stdin, not command arguments.

`git-api` now uses GitHub `operationId` strings directly. Run `git-api configure` to store a legacy default PAT token, or `git-api configure <profile>` to store and select a named PAT profile under `${XDG_DATA_HOME:-$HOME/.local/share}/git-api/profiles/`. Use `git-api profiles` to list stored profiles, `git-api use <profile>` to switch the current profile, and `git-api delete-profile <profile>` to remove one. `git-api list` shows indexed operations, `git-api list repos/` filters by prefix, and `git-api show <operationId>` inspects the docs URL and parameter requirements derived from the OpenAPI method file. Call an operation with `git-api <operationId> <required-path-args...> [query flags]`. Path parameters are passed in order from the URL template, while query parameters are passed as flags such as `--per-page 10` or `--q picotools`. Use `--field KEY=VALUE` for JSON body fields, `--body-file PATH` for a raw request body, `--token TOKEN` to override auth for a single invocation, `--token-stdin` to read one override token from stdin without placing it in process arguments, and `--profile NAME` to select a stored token profile for one call. `--token` and `--token-stdin` have the same highest precedence and cannot be combined. When neither explicit override is supplied, authentication is optional via the selected named profile, supported token environment variables, or the legacy token stored by `git-api configure`. The default GitHub API version header is `2026-03-10`, and `--api-root` or `--api-version` can override it.

`git-release-setup` automates the repository setup needed for release-tag dispatch workflows that fetch over SSH. It generates a temporary ed25519 keypair with `ssh-keygen`, uploads the private key to GitHub Actions as a repo secret through `git-api`, uploads the public key as a writable deploy key, enables repository workflow write permissions plus pull request review approvals for GitHub Actions, and sets fork PR contributor approval to `first_time_contributors_new_to_github` so first-time contributors who are new to GitHub still require approval. After the SSH setup, it can also optionally prompt for a local GPG secret key, validate the entered passphrase by exporting that key, and upload `RELEASE_GPG_PRIVATE_KEY`, `RELEASE_GPG_PASSPHRASE`, and `RELEASE_USER_EMAIL` as encrypted repository secrets. It requires `git-api`, `jq`, `python3`, `ssh-keygen`, `gpg`, and `PyNaCl` for the GitHub secret encryption step.

`git-clean-branches [--yes] [--debug] [--] [remote]` defaults to the `origin` remote. It first runs `git fetch --prune <remote>`, so invoking it may contact the selected remote and update or remove local remote-tracking refs before any deletion plan is shown. The optional positional remote may appear before or after options until `--`; use `--` when the remote name could otherwise look like an option. Unknown options and extra positional arguments fail before Git repository operations.

The cleanup plan force-deletes local branches whether merged or unmerged, except the freshly resolved remote default branch, the current branch, and any local branch currently checked out by a linked worktree. Remote branch candidates are limited to branches merged into the freshly resolved remote default branch, and the remote default and current branch are protected. By default the reviewed plan must be confirmed interactively; `--yes` skips only that prompt after printing the same plan. `--debug` prints progress details to stderr.

Before deletion, `git-clean-branches` rechecks the current branch, remote default branch name and OID, linked worktrees, local candidate OIDs, remote-tracking candidate OIDs, and remote branch OIDs. Local deletion uses an expected-OID compare-and-swap transaction. Remote deletion uses explicit `--force-with-lease` values in one `--atomic` push after confirming the remote supports atomic deletion. These guards reject stale reviewed plans, but local and remote deletion are separate phases: local deletion can complete before a later remote failure, no rollback is attempted, and the command prints a cleanup summary showing succeeded, stale/skipped, failed, and not-attempted branches. The final remote default check and remote deletion push cannot be combined into one server-side transaction, so a remote default movement after that check but before the push remains a residual race.

`asdf-clean-unused` ignores common generated directories such as `node_modules`, `dist`, `build`, `coverage`, `tmp`, `vendor`, `mnt`, `lost+found`, and virtualenv folders while scanning for `.tool-versions`. Use `--ignore-path PATH` to add more ignored paths. It prompts before removing unused plugins and versions by default; use `asdf-clean-unused --yes` to skip the confirmation.

`asdf-cli-install` fetches the most recent `asdf-vm/asdf` GitHub releases (default 10) through the GitHub API, marks the currently installed asdf CLI version with `(installed)`, and installs the selected version on the local machine by downloading the matching `linux/darwin` + `amd64/arm64` tarball and placing the `asdf` binary under `--prefix` (default `$ASDF_DATA_DIR/bin` or `$HOME/.asdf/bin`) with `--shims-dir` (default `$ASDF_DATA_DIR/shims` or `$HOME/.asdf/shims`) reported as the next PATH entry. Pass a bare version or `v`-prefixed tag positional argument to skip the picker and install that version directly. When the selected version equals the currently installed one it skips re-install. Use `--max-releases N` to change the list size, `--yes` to skip the install confirmation, and `--debug` for progress on stderr. It requires `curl` and `tar`, and prefers `GITHUB_API_TOKEN`, `GH_TOKEN`, `GITHUB_TOKEN`, or `PAT_TOKEN` for higher rate limits.

`asdf-upgrade` inspects `asdf current` in the current directory, keeps only installed tools whose active version and available upgrades are strict stable `<major>.<minor>.<patch>` releases, shows the tools with newer versions in a table, and lets you multi-select which entries to rewrite across one or more `.tool-versions` files together. After rewriting the selected entries, it can also run `asdf install` for you. Use `asdf-upgrade --yes` to update every listed tool without prompting.

`pip-upgrade` updates exact `==` requirement pins and supports `--scope major`, `--scope minor`, and `--scope patch` to control how far upgrades may move from the currently pinned version. It prompts before writing changes by default; use `--yes` to skip the confirmation.

`npm-publish-package` reads the current `package.json`, runs `pnpm bundle` by default, writes a publish-ready `package.json` into `dist`, copies `LICENSE`, `README.md`, and `CHANGELOG.md` when present, and publishes once for the main package name plus any `additionalNames`. It requires `jq` and `npm`, and the default bundle step also expects `pnpm` unless you override it with `--bundle-command` or skip it with `--skip-bundle`. `--workspace-root` lets you run the tool from a subdirectory, and when `./.npm-publish-package.json` exists in that workspace root, the tool reads JSON config defaults from it before applying CLI overrides. Explicit `--config PATH` values are resolved from the caller's current directory. Supported config keys mirror the long flags in camelCase, including `publishDir`, `packageJson`, `bundleCommand`, `skipBundle`, `includeFiles`, `ignoreMissingIncludeFile`, `defaultFiles`, `tolerateExistingPackageJson`, `access`, `tag`, `registry`, `otp`, `provenance`, and `dryRun`. See `./.npm-publish-package.json.example` for a template. `--publish-dir` must stay relative to the workspace root and cannot be `.` so published entrypoint paths can be rewritten safely, and the tool fails fast if the bundle step does not produce that directory. Explicit `--include-file` entries fail when missing unless `--ignore-missing-include-file` is set, and an existing publish-dir `package.json` is protected unless `--tolerate-existing-package-json` is passed. Use `--access` to override the npm access level, `--tag` to publish under a specific dist-tag, `--registry` to target a non-default registry, `--otp` for npm 2FA, `--provenance` to request provenance attestation, and `--dry-run` to prepare the publish artifacts without calling `npm publish`.

`oc-route` requires `oc`. It supports `list`, `read`, and `update`. `read --interactive` shows the existing route list and prompts for a selection. `update --interactive` shows existing routes so you can pick one to update or type a new route name to create, prompts for the target `Service`, and always includes a `tls` block with `termination` and `insecureEdgeTerminationPolicy`. Certificate inputs are only collected when you choose to provide them. Without `--interactive`, `update` requires route values to be passed as flags and supports certificate inputs via `--certificate`, `--key`, `--ca-certificate`, or the corresponding `*-file` flags.

`oc-quota-requests` requires `oc` with access to `oc adm top pods`. It reads `requests.cpu` and `requests.memory` from `compute-long-running-quota` by default, sums each pod's effective requests, normalizes CPU to millicores and memory to Mi, and compares the totals with current pod usage from metrics. It also evaluates the selected quota's `spec.scopes` and `scopeSelector` so the report can show which pods are likely counted by that quota and which are excluded, and it skips Job-owned pods from the quota-comparison totals. Use `--namespace` to target another namespace or `--quota-name` to override the quota resource name.

`git-clean-task-pr` first tries `git remote set-head <remote> --auto`, then falls back to cached local Git refs, and finally uses `main` when `refs/remotes/<remote>/main` exists. It also prompts for a new branch name and suggests `<current-branch>-1` or increments a trailing `-<number>` suffix such as `feat/1234-1` to `feat/1234-2`.

`license` writes `LICENSE` in the current directory by default. It prompts you to choose `MIT License` or `Apache License 2.0`, asks before overwriting an existing file, updates `package.json` in the current directory when present, supports `--type` for non-interactive runs, and accepts an optional output path. It always requires a copyright owner for all supported license types and defaults that prompt from `package.json.author` when available. For Apache 2.0, copyright years are optional and the interactive flow lets you choose among omitting years, deriving them from git history, or entering them manually. For CI or scripted use, `--copyright-owner` or `--owner` works for all supported license types, and `--copyright-years` or `--years` supplies the Apache years directly.

`inotify-watches` scans `/proc/<pid>/fdinfo/*` for `inotify wd:` entries, sums each process's watch count, and prints a summary table of the system-wide total against the current `fs.inotify.max_user_watches` limit followed by a top-consumers table sorted by watch count. Use `-n`/`--top N` to control how many consumers to show (default 10), `--all` to show every process, and `-z`/`--show-zeros` to include processes with zero recorded watches. It reads `cmdline` (or falls back to `comm`) for the command column and warns when the total exceeds the limit. Pass `-k`/`--kill` to enter the kill flow after printing the table: it opens a multi-select menu of the listed consumers, asks for confirmation, then sends the chosen signal (default `TERM`, override with `-s`/`--signal`) to each PID. Use `--dry-run` to print the kill commands without sending them and `--yes` to skip the confirmation prompt. Without a TTY the multi-select is skipped and you must pass explicit PID(s) via repeatable `-p`/`--pid` flags or trailing positional arguments; `--pid` and positional PIDs always force kill mode.

All tools support `--help`, `--version`, and `--debug`. The version is read from the repository `VERSION` file.

Single-choice interactive menus use arrow-key navigation when both stdin and stderr are attached to a terminal, and fall back to numbered prompts in non-interactive flows.

## Install

### via asdf

Add the plugin:

```sh
asdf plugin add picotools
# or
asdf plugin add picotools https://github.com/egose/picotools.git
```

Install and activate a version:

```sh
# List all available versions
asdf list all picotools

# Install a specific version
asdf install picotools <version>

# Install the latest stable version
asdf install picotools latest

# Set the global version
asdf global picotools <version>
```

Once installed, the tools are available directly on your `PATH`:

```sh
asdf-install
asdf-cli-install
asdf-upgrade
asdf-clean-unused
pip-upgrade
npm-publish-package
oc-route
oc-quota-requests
gh-repo-sync
gh-actions-upgrade
gh-release-assets
pre-commit-upgrade
model-profile
git-profile
git-commit
git-api
git-release-setup
git-clean-branches
git-clean-task-pr
license
inotify-watches
```

Please check the [asdf documentation](https://github.com/asdf-vm/asdf) for more details.

## License

See [LICENSE](LICENSE) © [Junmin Ahn](https://github.com/junminahn/)
