# Changelog

## 0.1.0 (2026-09-08)


### Features

* **actions-runner:** add nix to actions-runner image with database init ([#4](https://github.com/unmango/containers/issues/4)) ([87817ee](https://github.com/unmango/containers/commit/87817eeba7283e978fd699513bda6c0dd8a3147a))
* **actions-runner:** support a volume mounted at /nix ([#21](https://github.com/unmango/containers/issues/21)) ([a5134f1](https://github.com/unmango/containers/commit/a5134f1ca4011696da7cd1eee494590d23ab5927))
* add release-please for automated versioning and releases ([a807290](https://github.com/unmango/containers/commit/a8072902a2d1254b8397cb8c152677cadcd7f77b))
* build and publish third-party container images with nix2container ([#1](https://github.com/unmango/containers/issues/1)) ([78a771a](https://github.com/unmango/containers/commit/78a771ab6045ab55f3af8073622f66bbd0935fe2))
* **ci:** add release-please workflow for automated versioning and image retagging ([#20](https://github.com/unmango/containers/issues/20)) ([a807290](https://github.com/unmango/containers/commit/a8072902a2d1254b8397cb8c152677cadcd7f77b))
* **ci:** add variant support for sharing image repositories ([#14](https://github.com/unmango/containers/issues/14)) ([bdf4a37](https://github.com/unmango/containers/commit/bdf4a37f4a494d7e1d1d6e1e232931730c7f136b))
* **hercules-ci-agent:** add production-ready image configuration ([#13](https://github.com/unmango/containers/issues/13)) ([6777afc](https://github.com/unmango/containers/commit/6777afc9fb2e4e13ab44549148c906bb1021c53a))
* **images:** add standalone hercules-ci-agent image variant with bundled Nix store ([bdf4a37](https://github.com/unmango/containers/commit/bdf4a37f4a494d7e1d1d6e1e232931730c7f136b))


### Bug Fixes

* **actions-runner:** put the nix profile on PATH ([#22](https://github.com/unmango/containers/issues/22)) ([af7b7c6](https://github.com/unmango/containers/commit/af7b7c6180a1dabf57542a32925b93effcb78a22))
* **ci:** start release-please at 0.1.0 ([#24](https://github.com/unmango/containers/issues/24)) ([2ad75b3](https://github.com/unmango/containers/commit/2ad75b3ec2703922299b499787d14a65b4bd5692))


### Documentation

* **actions-runner:** note the initializeNixDatabase phantom paths ([#16](https://github.com/unmango/containers/issues/16)) ([d083a6e](https://github.com/unmango/containers/commit/d083a6e8cd5668ff554d49c9d8690aaa3f7aa95a))
* add AI agent instructions for project context ([#2](https://github.com/unmango/containers/issues/2)) ([96e68e7](https://github.com/unmango/containers/commit/96e68e7265c576f1e85ad5b09a8aa34ec5d080ad))
* add standalone variant for hercules-ci-agent and document variant system ([bdf4a37](https://github.com/unmango/containers/commit/bdf4a37f4a494d7e1d1d6e1e232931730c7f136b))


### Code Refactoring

* **actions-runner:** simplify image config by replacing arch-specific configs with a single shared config file ([a93be21](https://github.com/unmango/containers/commit/a93be21608a7664ea10042c2bf6c502664916bdd))
* **ci:** extract reusable setup action for Nix and Cachix ([#19](https://github.com/unmango/containers/issues/19)) ([a93be21](https://github.com/unmango/containers/commit/a93be21608a7664ea10042c2bf6c502664916bdd))
* consolidate per-system config files into a single config.json ([a93be21](https://github.com/unmango/containers/commit/a93be21608a7664ea10042c2bf6c502664916bdd))
* **hercules-ci-agent:** extract shared image config into common.nix ([bdf4a37](https://github.com/unmango/containers/commit/bdf4a37f4a494d7e1d1d6e1e232931730c7f136b))
* **scripts/update-manifest.sh:** consolidate per-arch config files into a single shared config.json ([a93be21](https://github.com/unmango/containers/commit/a93be21608a7664ea10042c2bf6c502664916bdd))


### Continuous Integration

* add additional cachix cache sources for mangopkgs and unmango ([#17](https://github.com/unmango/containers/issues/17)) ([be56a41](https://github.com/unmango/containers/commit/be56a41230bbffa231bc78796f7968fd09fd0300))
