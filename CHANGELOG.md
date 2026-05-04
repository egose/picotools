## [0.19.0](https://github.com/egose/picotools/compare/v0.18.0...v0.19.0) (2026-05-04)

### Features

* derive scope from monorepo module when branch scope is unavailable ([56694fd](https://github.com/egose/picotools/commit/56694fd758dfe3d8ebbbbafe06773992962d22ba))
* prefer package.json name for monorepo scope ([00bf408](https://github.com/egose/picotools/commit/00bf4087c959b7f36fba16e9c3c3a9c935e62519))

## [0.18.0](https://github.com/egose/picotools/compare/v0.17.0...v0.18.0) (2026-05-03)

### Features

* add ci to allowed commit types ([944aea2](https://github.com/egose/picotools/commit/944aea2a8f401431aca49b55bd0db5fe6770cb19))
* support file-based message arguments in model-provider ([cf7bd47](https://github.com/egose/picotools/commit/cf7bd47e61282dfe6a775a90e093d0191b12013f))
* use file-based messaging for git-commit LLM requests ([b1c0e70](https://github.com/egose/picotools/commit/b1c0e7056bf2a31c9a2a8249f151cdd4e889cf9e))

### Docs

* update bash tool conventions for picotools loading and shared helpers ([f8667b7](https://github.com/egose/picotools/commit/f8667b768eeb015e01b2827e8a89fcb9a9c57665))

## [0.17.0](https://github.com/egose/picotools/compare/v0.16.0...v0.17.0) (2026-05-02)

### Features

* add asdf-upgrade tool ([ca76ddd](https://github.com/egose/picotools/commit/ca76ddd20fa0a437ee1a8ccf536480f9bd6af11e))
* add multi-select prompt utilities ([0ab3616](https://github.com/egose/picotools/commit/0ab36160b4aa3bea5ec3259c4f2a2d9d3a214763))
* improve git-commit pre-commit execution and path resolution ([f04d85f](https://github.com/egose/picotools/commit/f04d85f44caa6892f5a4688373c7e7dfb3757981))

## [0.16.0](https://github.com/egose/picotools/compare/v0.15.0...v0.16.0) (2026-05-01)

### Features

* change context update to sequential field selection ([9034dab](https://github.com/egose/picotools/commit/9034dab2575c207f910a375d565b1581608cc685))

## [0.15.0](https://github.com/egose/picotools/compare/v0.14.0...v0.15.0) (2026-05-01)

### Features

* add ssh-add on start preference and commands subcommand ([a7ab2c2](https://github.com/egose/picotools/commit/a7ab2c2e3e184c1bd1c91b49598f15f0e2d0cc4d))
* add utilization metrics and color-coded sizing indicators ([cdebe7a](https://github.com/egose/picotools/commit/cdebe7a77381518332e69c7ec39a9ca1280bc93b))
* log progress during pre-commit check attempts ([31e4a40](https://github.com/egose/picotools/commit/31e4a40aba1a4ec7f1c0c80d3142c8baf4bfcd26))
* support ANSI escape sequences in table alignment ([483efbb](https://github.com/egose/picotools/commit/483efbb3614bc552b0f470a24893f7f458917582))

### Refactors

* modernize shell patterns and tool-versions parsing ([24baa0d](https://github.com/egose/picotools/commit/24baa0dd32fdc6b55ef292d82e7e7f1bb8b3dce3))

## [0.14.0](https://github.com/egose/picotools/compare/v0.13.0...v0.14.0) (2026-05-01)

### Features

* remove interactive selection from list command ([10b9b24](https://github.com/egose/picotools/commit/10b9b249f8037c213ed64425e3760828ff1e20aa))

## [0.13.0](https://github.com/egose/picotools/compare/v0.12.0...v0.13.0) (2026-05-01)

### Features

* add interactive selection prompt supporting arrow-key navigation ([602bd03](https://github.com/egose/picotools/commit/602bd034a4163bb9f924a808fcf8d875b252da43))
* add worktree awareness and remote head filtering to git-clean-branches ([95e1247](https://github.com/egose/picotools/commit/95e12475fc51d2de45b6569747774a3ee39b8dcf))
* migrate tools to use interactive selection prompt ([0b18dea](https://github.com/egose/picotools/commit/0b18dea17c6d4ebc855c480792921f974291582f))

## [0.12.0](https://github.com/egose/picotools/compare/v0.11.0...v0.12.0) (2026-04-30)

### Features

* add --pre-commit-retries option to git-commit ([68a9d24](https://github.com/egose/picotools/commit/68a9d243ffffc84c69cfb5a52ba4eaa08a8001e8))

## [0.11.0](https://github.com/egose/picotools/compare/v0.10.0...v0.11.0) (2026-04-30)

### Features

* implement --apply mode, scope overrides, and pre-commit integration ([15c87f2](https://github.com/egose/picotools/commit/15c87f2364fd60db91bf78fe7cea69580e8e181b))

## [0.10.0](https://github.com/egose/picotools/compare/v0.9.0...v0.10.0) (2026-04-29)

### Features

* add custom provider support to model-provider ([088de86](https://github.com/egose/picotools/commit/088de8644ba19224d5330cba24ee7e76c6d33f70))

## [0.9.0](https://github.com/egose/picotools/compare/v0.8.0...v0.9.0) (2026-04-29)

### Features

* add git-commit tool ([1886558](https://github.com/egose/picotools/commit/1886558cb108f3a65361bcde0449a2c474db1a47))
* add model-provider script ([4dd7803](https://github.com/egose/picotools/commit/4dd780316548404a803cd5787843b8ddfd75d988))
* add profiles and models commands to model-provider ([f79257b](https://github.com/egose/picotools/commit/f79257be0df7d35743dfc52fdd3e793ab63fd339))

## [0.8.0](https://github.com/egose/picotools/compare/v0.7.0...v0.8.0) (2026-04-28)

### Features

* add git-context script ([f768554](https://github.com/egose/picotools/commit/f76855470e0c8bf449ddd7dafffec45cdda833a3))

### Refactors

* extract shared bash helpers for reusable script logic ([ffbf6e3](https://github.com/egose/picotools/commit/ffbf6e3432f95eb4cd7f7965784c580841905fea))

## [0.7.0](https://github.com/egose/picotools/compare/v0.6.0...v0.7.0) (2026-04-24)

### Features

* add oc-quota-requests script ([248bd64](https://github.com/egose/picotools/commit/248bd648ce9bf7136f2b9d8fc2774056ad213444))

## [0.6.0](https://github.com/egose/picotools/compare/v0.5.1...v0.6.0) (2026-04-22)

### Features

* add oc-route script ([137069c](https://github.com/egose/picotools/commit/137069c9b2eecb522d5166a2a6e11f2e9f225bcf))

## [0.5.1](https://github.com/egose/picotools/compare/v0.5.0...v0.5.1) (2026-04-21)

### Bug Fixes

* **git-clean-task-pr:** resolve bug prompt swallowed by command substitution ([83b5860](https://github.com/egose/picotools/commit/83b5860e4d8434a6e7486561e27f698f8c3b12d9))

## [0.5.0](https://github.com/egose/picotools/compare/v0.4.0...v0.5.0) (2026-04-21)

### Features

* add asdf-clean-unused script ([356c393](https://github.com/egose/picotools/commit/356c3938074390de3f52bfc5d990687d2d50a269))

## [0.4.0](https://github.com/egose/picotools/compare/v0.3.0...v0.4.0) (2026-04-20)

### Features

* add git-clean-task-pr script ([199d049](https://github.com/egose/picotools/commit/199d0495d9257ab2c1f36f69ea764a6d87ba9ea1))

## [0.3.0](https://github.com/egose/picotools/compare/v0.2.0...v0.3.0) (2026-04-19)

### Features

* add git-clean-branches ([1e6272b](https://github.com/egose/picotools/commit/1e6272baface3e267a66fe337221e77e991fd5ea))

## [0.2.0](https://github.com/egose/picotools/compare/v0.1.1...v0.2.0) (2026-04-19)

### Features

* add gh-repo-sync ([c3dd50a](https://github.com/egose/picotools/commit/c3dd50a483e836caf1a7fb17a0bb4181d5a9b548))

## [0.1.1](https://github.com/egose/picotools/compare/v0.1.0...v0.1.1) (2026-04-19)

## [0.1.0](https://github.com/egose/picotools/compare/v0.0.2...v0.1.0) (2026-04-19)

### Features

* add initial tools ([1a57403](https://github.com/egose/picotools/commit/1a57403f5fbff8bd8bc2b604b938bf6dd6214033))

## 0.0.2 (2026-04-19)
