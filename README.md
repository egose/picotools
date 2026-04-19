# asdf-picotools

[asdf](https://github.com/asdf-vm/asdf) plugin and release repository for installable `picotools` bash scripts.

## Install

### Plugin

```sh
asdf plugin add picotools
# or
asdf plugin add picotools https://github.com/egose/asdf-picotools.git
```

### Tools

```sh
# List all versions of the bundled tool set
asdf list all picotools

# Install a specific version
asdf install picotools <version>

# Install the latest stable version
asdf install picotools latest

# Set the package global version
asdf global picotools <version>

# Run the installed scripts
hello-world
hello-world-again
```

Please check [asdf](https://github.com/asdf-vm/asdf) for more details.

# License

See [LICENSE](LICENSE) ©[Junmin Ahn](https://github.com/junminahn/)
