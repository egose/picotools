# picotools

A collection of installable bash scripts bundled as a release repository, with support for [asdf](https://github.com/asdf-vm/asdf) plugin-based installation.

## Tools

The following scripts are included in `tools/bin`:

| Tool | Description |
|------|-------------|
| `asdf-install` | Installs all tools defined in `.tool-versions` via asdf |
| `pip-upgrade` | Updates all packages in `requirements.txt` to their latest PyPI versions |
| `gh-repo-sync` | Downloads and caches all repos for a GitHub user/org |
| `git-clean-branches` | Deletes local branches and merged remote branches except the default/current branch |
| `git-clean-task-pr` | Creates a fresh PR branch by pulling the base branch, then soft-resetting to one staged commit |

`gh-repo-sync` requires `curl`, `jq`, and `unzip` to be available on the system.

`git-clean-branches` defaults to the `origin` remote and asks for confirmation before deleting branches. Use `git-clean-branches --yes` to skip the prompt.

`git-clean-task-pr` defaults to the remote default branch, prompts for a new branch name, and suggests `<current-branch>-1` or increments a trailing `-<number>` suffix such as `feat/1234-1` to `feat/1234-2`.

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
pip-upgrade
gh-repo-sync
git-clean-branches
git-clean-task-pr
```

Please check the [asdf documentation](https://github.com/asdf-vm/asdf) for more details.

## License

See [LICENSE](LICENSE) © [Junmin Ahn](https://github.com/junminahn/)
