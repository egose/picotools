# picotools

A collection of installable bash scripts bundled as a release repository, with support for [asdf](https://github.com/asdf-vm/asdf) plugin-based installation.

## Tools

The following scripts are included in `tools/bin`:

| Tool | Description |
|------|-------------|
| `hello-world` | Prints "hello world" |
| `hello-world-again` | Prints "hello world again" |
| `asdf-install` | Installs all tools defined in `.tool-versions` via asdf |
| `pip-upgrade` | Updates all packages in `requirements.txt` to their latest PyPI versions |
| `gh-repo-sync` | Downloads and caches all repos for a GitHub user/org |

`gh-repo-sync` requires `curl`, `jq`, and `unzip` to be available on the system.

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
hello-world
hello-world-again
```

Please check the [asdf documentation](https://github.com/asdf-vm/asdf) for more details.

## License

See [LICENSE](LICENSE) © [Junmin Ahn](https://github.com/junminahn/)
