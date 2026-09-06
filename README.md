# containers

Smörgåsbord of OCI containers.

Images that wrap third-party applications, built with [nix2container][] and published to both `ghcr.io/unmango/<name>` and `docker.io/unstoppablemango/<name>` for `linux/amd64` and `linux/arm64`.

Applications that live in their own repository publish their image from there instead.
This repository is only for wrapping software someone else wrote.

## Images

| Image                 | Wraps                                                                          |
| --------------------- | ------------------------------------------------------------------------------ |
| `actions-runner`      | [`ghcr.io/actions/actions-runner`][runner], plus static `nix`, `make` and `xz` |
| `coredns`             | [CoreDNS][]                                                                    |
| `gitlab-operator-v2`  | [GitLab Operator][]                                                            |
| `hercules-ci-agent`   | [Hercules CI agent][], also as a `-standalone` variant carrying a store        |
| `wireguard-cni-tools` | `wireguard-tools`, `iproute2`, `netcat`, coreutils, `bash`                     |

## Usage

```sh
docker pull ghcr.io/unmango/actions-runner:2.337.0
docker pull docker.io/unstoppablemango/coredns:1.14.6
```

| Tag                   | Moves                                                          |
| --------------------- | -------------------------------------------------------------- |
| `<version>`           | Every `main` build of that upstream version                    |
| `<version>-<release>` | Never. One per release of this repository, e.g. `1.14.6-0.3.1` |
| `sha-<short>`         | Never                                                          |
| `latest`              | Every `main` build                                             |

`<version>` is the wrapped application's version and `<release>` is this repository's, from its GitHub Releases.
`<version>-<release>` is a readable stand-in for a digest: the release workflow writes it once, from the digest the `sha-<short>` tag resolves to, and fails rather than move a tag that already points somewhere else.
Neither registry enforces that on its own, so pin by digest where the guarantee has to come from the registry.

Some images publish variants, which share a repository and differ by a tag suffix: `<version>-<variant>`, `<version>-<release>-<variant>`, `sha-<short>-<variant>`, plus `<variant>` in place of `latest`.
Swapping between them is a tag change.

### Renovate

Renovate's default `docker` versioning treats everything after the first hyphen as a compatibility marker, so it never proposes `1.14.6-0.3.1` to `1.14.6-0.3.2`.
The `loose` versioning compares the release part numerically:

```json
{
  "matchDatasources": ["docker"],
  "matchPackageNames": ["ghcr.io/unmango/**", "docker.io/unstoppablemango/**"],
  "versioning": "loose"
}
```

`loose` has no compatibility check, so a consumer of a variant also needs `"allowedVersions": "/-standalone$/"` (or the variant's name) to avoid being offered the plain image.

### `actions-runner`

Adds `nix`, `make` and `xz` to the upstream runner image, so a workflow needs no `cachix/install-nix-action` step.

Keeping the step is supported, and is the reason `PATH` carries `~/.nix-profile/bin`.
`install-nix-action` finds nix already on `PATH`, prints `Aborting: Nix is already installed`, and exits reporting success, which skips the line where it would have added that directory itself.
Anything a job installs with `nix-env -i` lands there, `cachix/cachix-action` among them, so without it that action installs `cachix` and then fails to find it.

Because the step aborts, its `extra_nix_config` input is ignored.
Per-deployment settings, a substituter above all, arrive as `NIX_CONFIG`, which nix merges on top of `/etc/nix/nix.conf`:

```yaml
env:
  NIX_CONFIG: |
    extra-substituters = https://cache.example.com
    extra-trusted-public-keys = cache.example.com:...
```

Use the `extra-` forms there.
A plain assignment replaces the image's value rather than adding to it.

The image ships nothing under `/nix` and brings no store of its own.
Its `/usr/local/bin` holds statically linked binaries rather than the usual symlinks into the store, so mounting anything at `/nix` is a supported thing to do rather than something that hides the tools.

`/etc/nix/nix.conf` sets `store = local` to make that work.
Nix's default `auto` store abandons `/nix` for a chroot store under `$HOME` whenever `/nix/var/nix` is missing, which is the state of every empty volume, and it does so with a warning rather than an error.
Naming the local store makes nix create that layout under `/nix` instead.

Nothing prepares the volume: nix creates `store`, `var` and its build directory itself, with its own modes rather than the volume's, so an empty one is enough.
The only requirement is that the runner user, uid and gid 1001, can write to it.

Under [Actions Runner Controller][arc] that is an `emptyDir`, which kubelet creates mode `0777`, and no `fsGroup` or initContainer:

```yaml
template:
  spec:
    containers:
      - name: runner
        image: ghcr.io/unmango/actions-runner:2.337.0
        command: [/home/runner/run.sh]
        volumeMounts:
          - name: nix
            mountPath: /nix
    volumes:
      - name: nix
        emptyDir: {}
```

A PVC works too and holds the store across jobs, but arrives owned by root, so it needs `template.spec.securityContext.fsGroup: 1001` to be writable.

Garbage collection goes in `NIX_CONFIG` too, and is off unless asked for.
A store thrown away with its pod never needs it; one that outlives the pod, a node-local store shared by every runner scheduled there above all, grows until the disk is full.
`min-free` and `max-free` make nix collect mid-build, whenever free space falls under the first, until the second is available again:

```yaml
env:
  - name: NIX_CONFIG
    value: |
      min-free = 10737418240
      max-free = 21474836480
```

The image cannot pick those numbers, which is why it does not try: they are a fraction of a disk it knows nothing about, and they are wrong outright for an ephemeral store.
Temporary roots keep a collection from taking paths a running build is using, so concurrent runners sharing one store are fine.
What it does reclaim is a finished result nothing holds a root on, which is the point, and the reason to leave headroom rather than set `min-free` at the last free byte.

With no mount, nix creates `/nix` on the container filesystem and the store is discarded with the container.
That is the right shape for a throwaway runner and the wrong one for a real workload: a store on an overlayfs cannot tear down a build directory it has just emptied, failing with `cannot unlink ...: Directory not empty`, which derivations that write many small files hit reliably.

### `hercules-ci-agent`

Two modes, same repository:

| Tag                 | Nix store                     |
| ------------------- | ----------------------------- |
| `0.10.8`, `latest`  | the host's, mounted at `/nix` |
| `0.10.8-standalone` | shipped in the image          |

Both take their config the same way.
`--config /etc/hercules-ci-agent/agent.json` is the default `Cmd`; no config is baked in, so mount one there or pass `--config` yourself.
JSON rather than TOML, because TOML cannot express `null` in `labels` and silently drops subtables.
The config supplies `baseDirectory`, and the operator installs `cluster-join-token.key` and `binary-caches.json` under its `secrets` directory.
Leave `baseDirectory` at `/var/lib/hercules-ci-agent` or mount the state volume at whatever path you set it to.
The agent writes work directories and `secretState/session.key` under `baseDirectory` and nowhere else, so a mismatch leaves that state on the container's writable layer, where it is lost on the next `docker run`.

Both run as uid 1000, which must own the state volume.
Root is not an option: the agent refuses to host an effect as root.
Both images ship `/var/lib/hercules-ci-agent` and `/tmp` owned by uid 1000, so Docker seeds a fresh named volume with that ownership.
A bind mount keeps the host directory's ownership instead, so `chown 1000:1000` it first.
Effects additionally need working unprivileged user namespaces for `crun`; upstream reports they work under Podman but not under systemd-nspawn.

Neither mode needs a `nix-daemon`. The agent links Nix as a library, and for effects it spawns its own `hercules-ci-nix-daemon` proxy rather than using a host socket.

#### Host store

```sh
docker run \
  -v /nix:/nix \
  -v ./agent.json:/etc/hercules-ci-agent/agent.json:ro \
  -v hercules-state:/var/lib/hercules-ci-agent \
  ghcr.io/unmango/hercules-ci-agent:0.10.8
```

#### Standalone

Carries a registered store, so there is no `/nix` mount:

```sh
docker run \
  -v ./agent.json:/etc/hercules-ci-agent/agent.json:ro \
  -v hercules-state:/var/lib/hercules-ci-agent \
  ghcr.io/unmango/hercules-ci-agent:0.10.8-standalone
```

Set `nixUserIsTrusted = true` in the config: there is no daemon to refuse anything, and it saves materializing a full `.drv` closure on every build.

The shipped store and its Nix database are image layers, so removing a container discards only what a build added on top of them.
Mount a named volume at `/nix` to keep those additions: Docker copies the image's `/nix` into an empty named volume the first time it is mounted, so the shipped store is still there.
A bind mount, or `volume-nocopy`, skips that seeding and masks the store instead.
Nothing garbage-collects it either, because the agent registers no GC roots, so `nix` is on `PATH` for `nix store gc`.

## Development

```sh
make list          # image names
make meta          # image names, versions, and tags
make build         # build everything
make build-coredns # build one image
make load-coredns  # load one image into the local Docker daemon
make check         # nix flake check
make fmt           # nix fmt
```

### Adding an image

1. Create `images/<name>/default.nix`. Take `mkImage` as an argument and pass it a `name`, a `version`, and an OCI `config`.
   `mkImage` pins the OCI tag to `version`, which nix2container otherwise derives from the output hash and churns on every rebuild.
2. Register it in the `images` attrset in `images/default.nix`.

That is the whole cost. CI enumerates `legacyPackages.<system>.imageMeta`, which is derived from the same attrset, so no workflow needs editing.

### Adding a variant

A variant is a second build of the same application that shares its repository and differs by tag, the way `node:22` and `node:22-alpine` do.

1. Pass `variant = "<name>"` to `mkImage`, alongside the same `name` as the plain image. `mkImage` tags it `<version>-<variant>`, and CI publishes `<variant>` as its moving tag instead of `latest`.
2. Register it under its own key in the `images` attrset. The key is the flake attribute; `name` is the repository, so the two deliberately differ here.

Keep the shared parts in a `common.nix` beside the mode files rather than duplicating them, and open each mode file with a banner naming its mode.
`images/hercules-ci-agent/` is the worked example: `common.nix` holds everything both modes share, and `default.nix` and `standalone.nix` are short enough to read whole.

### Building on a base image

Add an `images/<name>/base.nix` holding the registry coordinates, then run `make manifest-<name>` to pin the base image's per-architecture manifests and its config.

Two things to know:

- `pullImageFromManifest` takes a single-architecture manifest, not a multi-arch index, so each system pins its own file.
- **nix2container replaces the base image's config rather than merging into it.** Anything not restated in your `config` is lost, including `PATH`. This is why the base config is pinned too, as one `config.json` shared by every system, and inherited explicitly. See `images/actions-runner/default.nix`.

A third trap, if you add tools on top of a base image: link them into `/usr/local` with `buildEnv`'s `extraPrefix`, never into `/`.
A layer containing a real `./bin` directory replaces the base image's `/bin -> usr/bin` symlink and hides everything the base image resolves through it.

If the image ships `nix` itself, set `initializeNixDatabase = true` so the store paths it carries are registered, and set `nixUid`/`nixGid` to the user that will build in that store.

Renovate bumps `version` in `base.nix` but cannot regenerate the pinned files, so `.github/workflows/update-manifests.yml` does it on Renovate branches and CI fails on drift.

### Releases

[release-please][] versions this repository as a whole.
After a successful Images run on `main`, and only where releasable commits have landed since the last release, it opens or updates a `chore(main): release` PR carrying `CHANGELOG.md` and `version.txt`.
Merging that PR tags `v<release>`, publishes a GitHub Release, and retags every image's `sha-<short>` as `<version>-<release>`, with no rebuild.

Every commit type with a visible changelog section in `release-please-config.json` is releasable: `feat`, `fix`, `deps`, `docs`, `refactor`, `perf`, `revert`, `test`, `build`, and `ci`.
`chore` is hidden and produces no release on its own.
`feat` bumps the minor and the rest the patch; a `!` after the type or a `BREAKING CHANGE` footer bumps the major, or the minor while the version is below 1.0.
Renovate's Nix and base image bumps are committed as `deps:` for this reason, while its GitHub Action pins stay `chore(deps)`.
Never hand-edit `version.txt` or `CHANGELOG.md`.

[arc]: https://github.com/actions/actions-runner-controller
[nix2container]: https://github.com/nlewo/nix2container
[release-please]: https://github.com/googleapis/release-please
[runner]: https://github.com/actions/runner
[CoreDNS]: https://coredns.io
[GitLab Operator]: https://gitlab.com/gitlab-org/cloud-native/gitlab-operator
[Hercules CI agent]: https://hercules-ci.com
