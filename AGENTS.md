# AGENTS.md

Nix flake that builds OCI images wrapping third-party applications with [nix2container][], published to `ghcr.io/unmango/<name>` and `docker.io/unstoppablemango/<name>` for `linux/amd64` and `linux/arm64`.

Only software someone else wrote belongs here.
Applications with their own repository publish their image from there.

`README.md` is the user-facing description and covers the same commands plus the procedure for adding an image.
Read it before making changes.

## Commands

The dev shell (`direnv allow`, or `nix develop`) supplies `jq`, `gnumake`, and the `skopeo-nix2container` fork that `copyTo` shells out to.
Plain nixpkgs `skopeo` does not understand the `nix:` transport.

```sh
make list             # image names
make meta             # image names, versions, and tags as JSON
make build            # build everything
make build-<name>     # build one image
make load-<name>      # load one image into the local Docker daemon
make push-<name>      # push one image (REGISTRY defaults to ghcr.io/unmango)
make manifests        # regenerate every pinned base manifest and config
make manifest-<name>  # regenerate one image's pins
make check            # nix flake check
make fmt              # nix fmt (treefmt)
```

There is no test suite.
`make check` and a successful `make build` are the whole verification story.

`make list` and `IMAGES` come from `nix eval` on `legacyPackages.<system>.imageMeta`, so they work without editing the Makefile when an image is added.
`SYSTEM` defaults to `builtins.currentSystem`; override it to enumerate for another system.

Images are Linux-only.
On Darwin the flake still evaluates and formats, but `packages` is empty.

## Architecture

`images/default.nix` is a flake-parts `perSystem` module holding the `images` attrset.
Registering an image there is the only wiring step: the Makefile, CI's build matrix, and `imageMeta` all derive from it.

Three surfaces come out of that attrset:

- `packages.<name>` — the images themselves, plus `<name>-archive` for those in `archives`, a `default` link farm of everything, and an `archives` link farm.
  Images are top-level packages rather than `passthru.image` on the wrapped package, because `passthru` hides them from `nix flake show`, from CI enumeration, and from other flakes.
- `legacyPackages.imageMeta` — `{ imageName, imageTag, version }` per image, the enumeration surface CI reads.
  It is `legacyPackages` because the values are attrsets and `nix flake check` rejects those under `packages`.
- Re-exported `nix2container-bin` and `skopeo-nix2container`, so those exact store paths land in the Cachix cache.

`images/lib/mk-image.nix` wraps `nix2container.buildImage` and pins the OCI tag to `version`.
nix2container otherwise derives the tag from the output hash, which churns on every unrelated closure change.
Every image should go through `mkImage`, not `buildImage` directly.

`images/lib/mk-archive.nix` converts an image into a docker-archive tarball for consumers that need a loadable file (NixOS' `seedDockerImages` cats the store path into `ctr image import`).
Archives are built but never published, which is why CI builds them from the `archives` aggregate rather than the image matrix.

Per-image files live in `images/<name>/default.nix` and take their dependencies as function arguments; `callPackage` is scoped to `pkgs` plus `mkImage`, the nix2container packages, and packages from the `unmango/pkgs` input.

### Base images

An image built on top of an upstream image adds `images/<name>/base.nix` holding registry coordinates as plain data, so `scripts/update-manifest.sh` can `nix eval --file` it rather than grepping Nix source.
`make manifest-<name>` writes `manifest-<system>.json` and `config-<system>.json` beside it.

Three traps, all of which `images/actions-runner/` demonstrates:

1. `pullImageFromManifest` takes a single-architecture manifest, not a multi-arch index, so each system pins its own file. It does not verify the platform either, hence the architecture check in the script.
2. **nix2container replaces the base image's config rather than merging into it.** Anything not restated in `config` is lost, `PATH` included. This is why the base config is pinned and inherited explicitly.
3. Link added tools into `/usr/local` with `buildEnv`'s `extraPrefix`, never into `/`. A layer with a real `./bin` directory replaces the base image's `/bin -> usr/bin` symlink and hides everything resolved through it.

Pinned manifests and configs are excluded from treefmt: manifests are stored verbatim as the registry served them, configs normalised through `jq --sort-keys`.
Reformatting them would make CI's drift check compare against prettier's output.

Renovate bumps `version` in `base.nix` but cannot regenerate the pins, so `.github/workflows/update-manifests.yml` runs `make manifests` on `renovate/**` branches and pushes with a PAT (`GITHUB_TOKEN` pushes do not re-trigger workflows).
CI's `manifests` job fails on drift.

## CI

`ci.yml` runs `make check` across x86_64-linux, aarch64-linux, and aarch64-darwin, builds `.#archives` on the Linux legs, and checks manifest drift.
`images.yml` enumerates `imageMeta`, builds and pushes per-arch `<sha>-<arch>` tags, then assembles the multi-arch index with `docker buildx imagetools create` (skopeo has no index-create verb).

Both workflows end in a single summary job (`build`, `image`) that fails unless every needed job succeeded, because matrix legs cannot be named as required checks in a ruleset.

Publishing is guarded on `github.ref == refs/heads/<default branch>` rather than merely "not a pull request", since `workflow_dispatch` accepts any ref.
Matrix values reach shell steps through `env:` rather than interpolation, because a pull request controls the image names in its own flake.

Action versions are pinned to commit SHAs with a trailing `# vX.Y.Z` comment; keep that form when adding steps.

[nix2container]: https://github.com/nlewo/nix2container
