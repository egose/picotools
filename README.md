# picotools

A collection of installable bash scripts bundled as a release repository, with support for [asdf](https://github.com/asdf-vm/asdf) plugin-based installation.

## Tools

The following scripts are included in `tools/bin`:

| Tool | Description |
|------|-------------|
| `asdf-install` | Installs all tools defined in `.tool-versions` via asdf |
| `asdf-upgrade` | Finds newer stable strict-semver asdf versions and updates selected `.tool-versions` entries |
| `asdf-clean-unused` | Scans workspace `.tool-versions` files and removes unused asdf plugins or versions |
| `pip-upgrade` | Updates exact requirement pins in `requirements.txt` within a selected version scope |
| `npm-publish-package` | Bundles a package, rewrites publish metadata, and publishes one or more package names from a publish directory |
| `oc-route` | Lists, reads, and interactively applies OpenShift route manifests |
| `oc-quota-requests` | Analyzes OpenShift namespace CPU and memory request quota usage |
| `gh-repo-sync` | Downloads and caches all repos for a GitHub user/org |
| `gh-actions-upgrade` | Updates pinned GitHub Action refs under `.github` to the latest tag or tag commit hash |
| `model-provider` | Stores named model provider profiles with config and token data kept separately |
| `git-commit` | Uses a configured model provider to propose and create conventional commits from workspace changes |
| `git-api` | Calls GitHub REST operations by `operationId` using split OpenAPI method files |
| `git-release-setup` | Generates a release SSH keypair, stores it as an Actions secret, and configures matching deploy-key permissions |
| `git-clean-branches` | Deletes local branches and merged remote branches except the default/current branch |
| `git-clean-task-pr` | Creates a fresh PR branch by pulling the base branch, then soft-resetting to one staged commit |
| `license` | Creates or updates a LICENSE file from MIT or Apache 2.0 templates |

`gh-repo-sync` requires `curl`, `jq`, and `unzip` to be available on the system.

`gh-actions-upgrade` scans `.github/**/*.yml` and `.github/**/*.yaml` by default, updates `uses: owner/repo@ref` entries to each action repository's latest tag, prefers stable version tags over prereleases when both exist, and preserves each ref's current style unless `--ref-type tag` or `--ref-type hash` is used to force all rewritten refs to one form. It ignores local `./...` actions and `docker://...` references, requires `git` plus `sort`, and uses `GH_TOKEN`, `GITHUB_TOKEN`, `GITHUB_PAT`, or `PAT_TOKEN` for authenticated lookups when private action repositories need access.

`model-provider` stores provider metadata under `~/.config/model-provider` and tokens under `~/.local/share/model-provider`. It supports `azure-openai`, `azure-cognitive-services`, `gemini`, and `custom` profiles with `create`, `update`, `list`, `read`, `profiles`, `models`, `ask`, and `delete`. Azure providers store a resource name, while `custom` stores an explicit OpenAI-compatible endpoint URL. `list` shows the saved profiles and can display a selected profile's details inline. `ask` uses OpenAI-compatible `chat/completions` requests and requires `curl` and `jq`. Use `model-provider ask <profile> --message TEXT` to send a prompt, `--message-file PATH` for larger prompts, `--model MODEL` to override the default first configured model, and `--system-message TEXT` or `--system-message-file PATH` to override the default system prompt. `--user-message` is accepted as an alias for `--message`. Use `--debug` to print request-phase steps to stderr. `MODEL_PROVIDER_DEBUG=true` still works as a deprecated fallback, and `MODEL_PROVIDER_CURL_MAX_TIME=<seconds>` bounds request duration.

`git-commit` stores its selected model profile and model under `~/.config/git-commit/config`. Run `git-commit configure` first; if `git-api` named PAT profiles are present, it will also offer an optional `git-api` profile selection to use for pull-request creation. Then run `git-commit` inside a Git repository to ask the configured model for a conventional-commit plan and print shell-escaped `git add` and `git commit -m ...` commands for one or more commits from the current workspace changes. Planned `files` coverage is strict even for a single commit, and commit messages must start with an imperative lower-case verb. If staged changes already exist, it can optionally unstage them with `git restore --staged :/` before generating the preview. In monorepos, derived scopes prefer the leaf package name instead of repeating the npm org prefix. Use `--debug` to print progress steps to stderr, `--apply` to create the planned commits, `--push` to imply `--apply` and push them afterward, and `--pr` to imply `--apply --push` and open or update a pull request through `git-api`. In `--pr` mode, the model must return both `pull_request.title` and `pull_request.body`. `--pr` accepts an optional base branch; when omitted, `git-commit` resolves the repository default branch through `git-api` and falls back to git remote metadata.

`git-api` now uses GitHub `operationId` strings directly. Run `git-api configure` to store a legacy default PAT token, or `git-api configure <profile>` to store and select a named PAT profile under `~/.local/share/git-api/profiles/`. Use `git-api profiles` to list stored profiles, `git-api use <profile>` to switch the current profile, and `git-api delete-profile <profile>` to remove one. `git-api list` shows indexed operations, `git-api list repos/` filters by prefix, and `git-api show <operationId>` inspects the docs URL and parameter requirements derived from the OpenAPI method file. Call an operation with `git-api <operationId> <required-path-args...> [query flags]`. Path parameters are passed in order from the URL template, while query parameters are passed as flags such as `--per-page 10` or `--q picotools`. Use `--field KEY=VALUE` for JSON body fields, `--body-file PATH` for a raw request body, `--token TOKEN` to override auth for a single invocation, and `--profile NAME` to select a stored token profile for one call. Authentication is optional via named profiles, `--token`, `PAT_TOKEN`, `GH_TOKEN`, `GITHUB_PAT`, or the legacy token stored by `git-api configure`. The default GitHub API version header is `2026-03-10`, and `--api-root` or `--api-version` can override it.

`git-release-setup` automates the repository setup needed for release-tag dispatch workflows that fetch over SSH. It generates a temporary ed25519 keypair with `ssh-keygen`, uploads the private key to GitHub Actions as a repo secret through `git-api`, uploads the public key as a writable deploy key, and enables repository workflow write permissions plus pull request review approvals for GitHub Actions. After the SSH setup, it can also optionally prompt for a local GPG secret key, validate the entered passphrase by exporting that key, and upload `RELEASE_GPG_PRIVATE_KEY`, `RELEASE_GPG_PASSPHRASE`, and `RELEASE_USER_EMAIL` as encrypted repository secrets. It requires `git-api`, `jq`, `python3`, `ssh-keygen`, `gpg`, and `PyNaCl` for the GitHub secret encryption step.

`git-clean-branches` defaults to the `origin` remote and asks for confirmation before deleting branches. Use `git-clean-branches --yes` to skip the prompt.

`asdf-clean-unused` ignores common generated directories such as `node_modules`, `dist`, `build`, `coverage`, `tmp`, `vendor`, `mnt`, `lost+found`, and virtualenv folders while scanning for `.tool-versions`. Use `--ignore-path PATH` to add more ignored paths. It prompts before removing unused plugins and versions by default; use `asdf-clean-unused --yes` to skip the confirmation.

`asdf-upgrade` inspects `asdf current` in the current directory, keeps only installed tools whose active version and available upgrades are strict stable `<major>.<minor>.<patch>` releases, shows the tools with newer versions in a table, and lets you multi-select which entries to rewrite across one or more `.tool-versions` files together. After rewriting the selected entries, it can also run `asdf install` for you. Use `asdf-upgrade --yes` to update every listed tool without prompting.

`pip-upgrade` updates exact `==` requirement pins and supports `--scope major`, `--scope minor`, and `--scope patch` to control how far upgrades may move from the currently pinned version. It prompts before writing changes by default; use `--yes` to skip the confirmation.

`npm-publish-package` reads the current `package.json`, runs `pnpm bundle` by default, writes a publish-ready `package.json` into `dist`, copies `LICENSE`, `README.md`, and `CHANGELOG.md` when present, and publishes once for the main package name plus any `additionalNames`. It requires `jq` and `npm`, and the default bundle step also expects `pnpm` unless you override it with `--bundle-command` or skip it with `--skip-bundle`. `--workspace-root` lets you run the tool from a subdirectory, and when `./.npm-publish-package.json` exists in that workspace root, the tool reads JSON config defaults from it before applying CLI overrides. Explicit `--config PATH` values are resolved from the caller's current directory. Supported config keys mirror the long flags in camelCase, including `publishDir`, `packageJson`, `bundleCommand`, `skipBundle`, `includeFiles`, `ignoreMissingIncludeFile`, `defaultFiles`, `tolerateExistingPackageJson`, `access`, `tag`, `registry`, `otp`, `provenance`, and `dryRun`. See `./.npm-publish-package.json.example` for a template. `--publish-dir` must stay relative to the workspace root and cannot be `.` so published entrypoint paths can be rewritten safely, and the tool fails fast if the bundle step does not produce that directory. Explicit `--include-file` entries fail when missing unless `--ignore-missing-include-file` is set, and an existing publish-dir `package.json` is protected unless `--tolerate-existing-package-json` is passed. Use `--access` to override the npm access level, `--tag` to publish under a specific dist-tag, `--registry` to target a non-default registry, `--otp` for npm 2FA, `--provenance` to request provenance attestation, and `--dry-run` to prepare the publish artifacts without calling `npm publish`.

`oc-route` requires `oc`. It supports `list`, `read`, and `update`. `read --interactive` shows the existing route list and prompts for a selection. `update --interactive` shows existing routes so you can pick one to update or type a new route name to create, prompts for the target `Service`, and always includes a `tls` block with `termination` and `insecureEdgeTerminationPolicy`. Certificate inputs are only collected when you choose to provide them. Without `--interactive`, `update` requires route values to be passed as flags and supports certificate inputs via `--certificate`, `--key`, `--ca-certificate`, or the corresponding `*-file` flags.

`oc-quota-requests` requires `oc` with access to `oc adm top pods`. It reads `requests.cpu` and `requests.memory` from `compute-long-running-quota` by default, sums each pod's effective requests, normalizes CPU to millicores and memory to Mi, and compares the totals with current pod usage from metrics. It also evaluates the selected quota's `spec.scopes` and `scopeSelector` so the report can show which pods are likely counted by that quota and which are excluded, and it skips Job-owned pods from the quota-comparison totals. Use `--namespace` to target another namespace or `--quota-name` to override the quota resource name.

`git-clean-task-pr` first tries `git remote set-head <remote> --auto`, then falls back to cached local Git refs, and finally uses `main` when `refs/remotes/<remote>/main` exists. It also prompts for a new branch name and suggests `<current-branch>-1` or increments a trailing `-<number>` suffix such as `feat/1234-1` to `feat/1234-2`.

`license` writes `LICENSE` in the current directory by default. It prompts you to choose `MIT License` or `Apache License 2.0`, asks before overwriting an existing file, updates `package.json` in the current directory when present, supports `--type` for non-interactive runs, and accepts an optional output path. It always requires a copyright owner for all supported license types and defaults that prompt from `package.json.author` when available. For Apache 2.0, copyright years are optional and the interactive flow lets you choose among omitting years, deriving them from git history, or entering them manually. For CI or scripted use, `--copyright-owner` or `--owner` works for all supported license types, and `--copyright-years` or `--years` supplies the Apache years directly.

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
asdf-upgrade
asdf-clean-unused
pip-upgrade
npm-publish-package
oc-route
oc-quota-requests
gh-repo-sync
gh-actions-upgrade
model-provider
git-commit
git-api
git-release-setup
git-clean-branches
git-clean-task-pr
license
```

Please check the [asdf documentation](https://github.com/asdf-vm/asdf) for more details.

## License

See [LICENSE](LICENSE) © [Junmin Ahn](https://github.com/junminahn/)
