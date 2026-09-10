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
- `legacyPackages.imageMeta` — `{ imageName, imageTag, version, variant }` per image, the enumeration surface CI reads.
  It is `legacyPackages` because the values are attrsets and `nix flake check` rejects those under `packages`.
  `imageName` is the published repository, not the attrset key; that separation is what lets variants share a repository.
- Re-exported `nix2container-bin` and `skopeo-nix2container`, so those exact store paths land in the Cachix cache.

`images/lib/mk-image.nix` wraps `nix2container.buildImage` and pins the OCI tag to `version`.
nix2container otherwise derives the tag from the output hash, which churns on every unrelated closure change.
Every image should go through `mkImage`, not `buildImage` directly.

**`copyToRoot` copies an entry's contents to `/` and leaves the entry's own store path out of the image.**
Two consequences.
A store path interpolated into `config` (`SSL_CERT_FILE=${cacert}/...`) dangles, resolving only when a host `/nix` happens to be mounted and happens to carry that exact path, so reference the `/etc` path the copy created instead.
And `initializeNixDatabase` registers the whole closure regardless, so the shipped database claims paths that are not there; pass the same roots through `nix2container.buildLayer { deps = ...; }` to materialize them.
`images/hercules-ci-agent/common.nix` does both, and `nix-store --verify` inside the image is how to check.

`images/lib/mk-archive.nix` converts an image into a docker-archive tarball for consumers that need a loadable file (NixOS' `seedDockerImages` cats the store path into `ctr image import`).
Archives are built but never published, which is why CI builds them from the `archives` aggregate rather than the image matrix.

Per-image files live in `images/<name>/default.nix` and take their dependencies as function arguments; `callPackage` is scoped to `pkgs` plus `mkImage`, the nix2container packages, and packages from the `unmango/pkgs` input.
That scope applies only to the outermost call: the `callPackage` an image file receives is plain `pkgs.callPackage`, so a file that calls a sibling has to pass `mkImage` and `nix2container` explicitly.

### Variants

Two builds of one application share a repository and differ by tag, the way `node:22` and `node:22-alpine` do.
`mkImage` takes `variant`, which suffixes the tag to `<version>-<variant>` and leaves `meta.version` as the plain upstream version, because that is what Renovate and consumers read.
CI publishes `<variant>` as the moving tag where an unvaried image publishes `latest`, so they never fight over it.

The published repository is `imageMeta.imageName`, not the attrset key.
Two variants therefore need distinct keys but the same `name`.
The key also goes into the per-arch staging tag (`<sha>-<key>-<arch>`), which is what keeps two variants from colliding while they wait for `index`.

Shared parts belong in a `common.nix` beside the mode files, with each mode file opening on a banner comment naming its mode; `images/hercules-ci-agent/` is the worked example.

### Base images

An image built on top of an upstream image adds `images/<name>/base.nix` holding registry coordinates as plain data, so `scripts/update-manifest.sh` can `nix eval --file` it rather than grepping Nix source.
`make manifest-<name>` writes `manifest-<system>.json` per system and one `config.json` beside it.
`make manifests` runs it for every directory that has a `base.nix`.

Three traps, all of which `images/actions-runner/` demonstrates:

1. `pullImageFromManifest` takes a single-architecture manifest, not a multi-arch index, so each system pins its own file. It does not verify the platform either, hence the architecture check in the script.
2. **nix2container replaces the base image's config rather than merging into it.** Anything not restated in `config` is lost, `PATH` included. This is why the base config is pinned and inherited explicitly. One `config.json` serves every system; the script fails if the architectures disagree.
3. Link added tools into `/usr/local` with `buildEnv`'s `extraPrefix`, never into `/`. A layer with a real `./bin` directory replaces the base image's `/bin -> usr/bin` symlink and hides everything resolved through it.

An image that ships a store of its own needs `initializeNixDatabase = true`, which registers the store paths it carries so nix sees a store rather than a pile of unknown files.
Set `nixUid`/`nixGid` alongside it: nix2container applies mode `0755` and those ids to the whole database path, so unlike `dockerTools`' `includeNixDB`, which writes `db.sqlite` 0600 root, no chmod pass is needed afterwards.
`images/hercules-ci-agent/common.nix` uses this for its standalone mode.

`images/actions-runner/` takes the opposite approach, shipping no store paths so that a consumer can mount a writable volume at `/nix`, which is what a store on an overlayfs is worth avoiding for.
Three things follow, and all three are the point rather than incidental.
Its tools are `pkgsStatic` builds copied into `/usr/local` as real files with `nuke-refs` run over them, because `buildEnv`'s `extraPrefix` would leave symlinks into a `/nix` the mount hides, and because a copied binary keeps its original's store paths as strings, which is enough for nix2container to ship 470MB of closure into a `/nix` nothing reads.
Its `nix.conf` sets `store = local`, because the default `auto` store abandons `/nix` for a chroot store under `$HOME` when `/nix/var/nix` is absent, which is every empty volume, and only warns about it.
And it ships an empty `/nix`, owned by the runner through `perms` rather than by the store path's own ownership, because Docker seeds a fresh named volume from the image's directory: without it that volume arrives owned by root and nix cannot write to it.

An image that ships `nix` also has to put the user profile's bin directory on `PATH` itself.
`cachix/install-nix-action` normally does that on its last line, but on such an image it finds nix already present, prints `Aborting: Nix is already installed` and exits reporting success, so the line never runs.
`cachix/cachix-action` is what notices: it installs `cachix` with `nix-env -i`, which lands in `~/.nix-profile/bin`, then resolves the name on `PATH` and fails with `not found: cachix`.
`images/actions-runner/default.nix` rewrites the base image's `PATH` entry rather than appending a second one, since runtimes disagree about which of two wins, and appends rather than prepends so a package installed into the profile cannot shadow the tools in `/usr/local/bin`.
The same abort discards the action's `extra_nix_config`, which is why consumers pass per-deployment settings as `NIX_CONFIG` instead.

Pinned manifests and configs are excluded from treefmt: manifests are stored verbatim as the registry served them, `config.json` is the `.config` block normalised through `jq --sort-keys`.
Reformatting them would make CI's drift check compare against prettier's output.

Renovate bumps `version` in `base.nix` but cannot regenerate the pins, so `.github/workflows/update-manifests.yml` runs `make manifests` on `renovate/**` branches and pushes with a PAT (`GITHUB_TOKEN` pushes do not re-trigger workflows).
CI's `manifests` job fails on drift.

## Versioning

The repository has one version, managed by release-please (`release-please-config.json`, `.release-please-manifest.json`, `version.txt`, `CHANGELOG.md`).
Never hand-edit those; the `chore(main): release` PR does.
The `simple` release type is used because the version is not needed inside Nix: CI derives the OCI tag from release-please's outputs.

`initial-version` is `0.1.0` because release-please has no version to bump from until a release exists, and the `0.0.0` in the manifest is not one: there is no tag or GitHub release behind it.
Without it the first release is release-please's own default of `1.0.0`, whatever the commits say.
The setting only applies to that first release and is inert afterwards.

Each image publishes `<version>-<release>[-<variant>]` per release alongside the moving `<version>` and `sha-<short>` tags, where `<version>` is upstream's and `<release>` is this repository's.
The variant stays last, matching `sha-<short>-<variant>`, which is why `release.yml` builds the tag from `imageMeta.version` rather than `imageTag`.
Consumers need Renovate's `loose` versioning to follow that tag; the default `docker` versioning treats the hyphen suffix as a compatibility marker.

Per-image versioning was rejected: release-please attributes commits to a component by the paths they touch, and a `flake.lock` bump touches no `images/<name>` path, so it would count toward nothing.

Release-please skips a release when every commit since the last one sits in a hidden changelog section.
`deps` is visible and `chore` hidden, so Renovate's Nix and `base.nix` managers commit as `deps:` (a `packageRules` entry in `.github/renovate.json`) and its GitHub Action pins, which do not change any image, stay `chore(deps)`.

## CI

`ci.yml` runs `make check` across x86_64-linux, aarch64-linux, and aarch64-darwin, builds `.#archives` on the Linux legs, and checks manifest drift.
`images.yml` enumerates `imageMeta`, builds and pushes per-arch `<sha>-<arch>` tags, then assembles the multi-arch index with `docker buildx imagetools create` (skopeo has no index-create verb).
`release.yml` runs on `workflow_run` after a successful Images run for a push to `main`, so a release is only cut for a commit whose images are published.
It runs release-please with a PAT (`RELEASE_PLEASE_TOKEN`), because a release PR opened with `GITHUB_TOKEN` triggers no workflows and could never pass the required checks.
When a release is created it re-enumerates `imageMeta` at the released commit and retags `sha-<short>` as `<version>-<release>` with `imagetools create`; nothing is rebuilt.
The source is the digest `sha-<short>` resolves to rather than the tag, so a re-run cannot pick up different content, and the step refuses to move a release tag that already points at a different digest, which is what lets the README describe that tag as written once.
Each registry resolves its own `sha-<short>`, so the two holding the same index follows from Images pushing identical content to both, not from anything the retag checks.

Checkout stays in each job because a local action cannot be referenced before the checkout exists; `.github/actions/setup` holds the Nix install and Cachix steps that follow it.

Each workflow ends in a single summary job (`build`, `image`, `release`) that fails unless every needed job succeeded, because matrix legs cannot be named as required checks in a ruleset.

Publishing is guarded on `github.ref == refs/heads/<default branch>` rather than merely "not a pull request", since `workflow_dispatch` accepts any ref.
Matrix values reach shell steps through `env:` rather than interpolation, because a pull request controls the image names in its own flake.

Action versions are pinned to commit SHAs with a trailing `# vX.Y.Z` comment; keep that form when adding steps.

[nix2container]: https://github.com/nlewo/nix2container
