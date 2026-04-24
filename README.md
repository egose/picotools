# picotools

A collection of installable bash scripts bundled as a release repository, with support for [asdf](https://github.com/asdf-vm/asdf) plugin-based installation.

## Tools

The following scripts are included in `tools/bin`:

| Tool | Description |
|------|-------------|
| `asdf-install` | Installs all tools defined in `.tool-versions` via asdf |
| `asdf-clean-unused` | Scans workspace `.tool-versions` files and removes unused asdf plugins or versions |
| `pip-upgrade` | Updates exact requirement pins in `requirements.txt` within a selected version scope |
| `oc-route` | Lists, reads, and interactively applies OpenShift route manifests |
| `oc-quota-requests` | Analyzes OpenShift namespace CPU and memory request quota usage |
| `gh-repo-sync` | Downloads and caches all repos for a GitHub user/org |
| `git-clean-branches` | Deletes local branches and merged remote branches except the default/current branch |
| `git-clean-task-pr` | Creates a fresh PR branch by pulling the base branch, then soft-resetting to one staged commit |

`gh-repo-sync` requires `curl`, `jq`, and `unzip` to be available on the system.

`git-clean-branches` defaults to the `origin` remote and asks for confirmation before deleting branches. Use `git-clean-branches --yes` to skip the prompt.

`asdf-clean-unused` ignores common generated directories such as `node_modules`, `dist`, `build`, `coverage`, `tmp`, `vendor`, `mnt`, `lost+found`, and virtualenv folders while scanning for `.tool-versions`. Use `--ignore-path PATH` to add more ignored paths. It prompts before removing unused plugins and versions by default; use `asdf-clean-unused --apply` to skip the confirmation.

`pip-upgrade` updates exact `==` requirement pins and supports `--scope major`, `--scope minor`, and `--scope patch` to control how far upgrades may move from the currently pinned version. It prompts before writing changes by default; use `--apply` to skip the confirmation.

`oc-route` requires `oc`. It supports `list`, `read`, and `update`. `read --interactive` shows the existing route list and prompts for a selection. `update --interactive` shows existing routes so you can pick one to update or type a new route name to create, prompts for the target `Service`, and always includes a `tls` block with `termination` and `insecureEdgeTerminationPolicy`. Certificate inputs are only collected when you choose to provide them. Without `--interactive`, `update` requires route values to be passed as flags and supports certificate inputs via `--certificate`, `--key`, `--ca-certificate`, or the corresponding `*-file` flags.

`oc-quota-requests` requires `oc` with access to `oc adm top pods`. It reads `requests.cpu` and `requests.memory` from `compute-long-running-quota` by default, sums each pod's effective requests, normalizes CPU to millicores and memory to Mi, and compares the totals with current pod usage from metrics. It also evaluates the selected quota's `spec.scopes` and `scopeSelector` so the report can show which pods are likely counted by that quota and which are excluded, and it skips Job-owned pods from the quota-comparison totals. Use `--namespace` to target another namespace or `--quota-name` to override the quota resource name.

`git-clean-task-pr` first tries `git remote set-head <remote> --auto`, then falls back to cached local Git refs, and finally uses `main` when `refs/remotes/<remote>/main` exists. It also prompts for a new branch name and suggests `<current-branch>-1` or increments a trailing `-<number>` suffix such as `feat/1234-1` to `feat/1234-2`.

All tools support `--help` and `--version`. The version is read from the repository `VERSION` file.

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
asdf-clean-unused
pip-upgrade
oc-route
oc-quota-requests
gh-repo-sync
git-clean-branches
git-clean-task-pr
```

Please check the [asdf documentation](https://github.com/asdf-vm/asdf) for more details.

## License

See [LICENSE](LICENSE) © [Junmin Ahn](https://github.com/junminahn/)
