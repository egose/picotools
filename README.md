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
| `oc-route` | Lists, reads, and interactively applies OpenShift route manifests |
| `oc-quota-requests` | Analyzes OpenShift namespace CPU and memory request quota usage |
| `gh-repo-sync` | Downloads and caches all repos for a GitHub user/org |
| `model-provider` | Stores named model provider profiles with config and token data kept separately |
| `git-commit` | Uses a configured model provider to propose and create conventional commits from workspace changes |
| `git-api` | Calls GitHub REST operations by `operationId` using split OpenAPI method files |
| `git-clean-branches` | Deletes local branches and merged remote branches except the default/current branch |
| `git-clean-task-pr` | Creates a fresh PR branch by pulling the base branch, then soft-resetting to one staged commit |

`gh-repo-sync` requires `curl`, `jq`, and `unzip` to be available on the system.

`model-provider` stores provider metadata under `~/.config/model-provider` and tokens under `~/.local/share/model-provider`. It supports `azure-openai`, `azure-cognitive-services`, `gemini`, and `custom` profiles with `create`, `update`, `list`, `read`, `profiles`, `models`, `ask`, and `delete`. Azure providers store a resource name, while `custom` stores an explicit OpenAI-compatible endpoint URL. `list` shows the saved profiles and can display a selected profile's details inline. `ask` uses OpenAI-compatible `chat/completions` requests and requires `curl` and `jq`. Use `model-provider ask <profile> --message TEXT` to send a prompt, `--message-file PATH` for larger prompts, `--model MODEL` to override the default first configured model, and `--system-message TEXT` or `--system-message-file PATH` to override the default system prompt. `--user-message` is accepted as an alias for `--message`. Use `--debug` to print request-phase steps to stderr. `MODEL_PROVIDER_DEBUG=true` still works as a deprecated fallback, and `MODEL_PROVIDER_CURL_MAX_TIME=<seconds>` bounds request duration.

`git-commit` stores its selected model profile and model under `~/.config/git-commit/config`. Run `git-commit configure` first, then run `git-commit` inside a Git repository to ask the configured model for a conventional-commit plan and print the `git add` and `git commit -m ...` commands for one or more commits from the current workspace changes. If staged changes already exist, it can optionally unstage them with `git restore --staged :/` before generating the preview. In monorepos, derived scopes prefer the leaf package name instead of repeating the npm org prefix. Use `--debug` to print progress steps to stderr, `--apply` to create the planned commits, `--push` to push them afterward, and `--pr` with `--apply --push` to open a pull request through `git-api`. `--pr` accepts an optional base branch; when omitted, `git-commit` resolves the repository default branch through `git-api` and falls back to git remote metadata.

`git-api` now uses GitHub `operationId` strings directly. Run `git-api configure` to store a PAT token for authenticated requests, `git-api list` to show all indexed operations, `git-api list repos/` to filter by prefix, and `git-api show <operationId>` to inspect the docs URL and parameter requirements derived from the OpenAPI method file. Call an operation with `git-api <operationId> <required-path-args...> [query flags]`. Path parameters are passed in order from the URL template, while query parameters are passed as flags such as `--per-page 10` or `--q picotools`. Use `--field KEY=VALUE` for JSON body fields, `--body-file PATH` for a raw request body, and `--token TOKEN` to override auth for a single invocation. Authentication is optional via `--token`, `PAT_TOKEN`, `GH_TOKEN`, `GITHUB_PAT`, or the token stored by `git-api configure`. The default GitHub API version header is `2026-03-10`, and `--api-root` or `--api-version` can override it.

`git-clean-branches` defaults to the `origin` remote and asks for confirmation before deleting branches. Use `git-clean-branches --yes` to skip the prompt.

`asdf-clean-unused` ignores common generated directories such as `node_modules`, `dist`, `build`, `coverage`, `tmp`, `vendor`, `mnt`, `lost+found`, and virtualenv folders while scanning for `.tool-versions`. Use `--ignore-path PATH` to add more ignored paths. It prompts before removing unused plugins and versions by default; use `asdf-clean-unused --yes` to skip the confirmation.

`asdf-upgrade` inspects `asdf current` in the current directory, keeps only installed tools whose active version and available upgrades are strict stable `<major>.<minor>.<patch>` releases, shows the tools with newer versions in a table, and lets you multi-select which entries to rewrite across one or more `.tool-versions` files together. After rewriting the selected entries, it can also run `asdf install` for you. Use `asdf-upgrade --yes` to update every listed tool without prompting.

`pip-upgrade` updates exact `==` requirement pins and supports `--scope major`, `--scope minor`, and `--scope patch` to control how far upgrades may move from the currently pinned version. It prompts before writing changes by default; use `--yes` to skip the confirmation.

`oc-route` requires `oc`. It supports `list`, `read`, and `update`. `read --interactive` shows the existing route list and prompts for a selection. `update --interactive` shows existing routes so you can pick one to update or type a new route name to create, prompts for the target `Service`, and always includes a `tls` block with `termination` and `insecureEdgeTerminationPolicy`. Certificate inputs are only collected when you choose to provide them. Without `--interactive`, `update` requires route values to be passed as flags and supports certificate inputs via `--certificate`, `--key`, `--ca-certificate`, or the corresponding `*-file` flags.

`oc-quota-requests` requires `oc` with access to `oc adm top pods`. It reads `requests.cpu` and `requests.memory` from `compute-long-running-quota` by default, sums each pod's effective requests, normalizes CPU to millicores and memory to Mi, and compares the totals with current pod usage from metrics. It also evaluates the selected quota's `spec.scopes` and `scopeSelector` so the report can show which pods are likely counted by that quota and which are excluded, and it skips Job-owned pods from the quota-comparison totals. Use `--namespace` to target another namespace or `--quota-name` to override the quota resource name.

`git-clean-task-pr` first tries `git remote set-head <remote> --auto`, then falls back to cached local Git refs, and finally uses `main` when `refs/remotes/<remote>/main` exists. It also prompts for a new branch name and suggests `<current-branch>-1` or increments a trailing `-<number>` suffix such as `feat/1234-1` to `feat/1234-2`.

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
oc-route
oc-quota-requests
gh-repo-sync
model-provider
git-commit
git-api
git-clean-branches
git-clean-task-pr
```

Please check the [asdf documentation](https://github.com/asdf-vm/asdf) for more details.

## License

See [LICENSE](LICENSE) © [Junmin Ahn](https://github.com/junminahn/)
