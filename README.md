# containers

Smörgåsbord of OCI containers.

Images that wrap third-party applications, built with [nix2container][] and published to both `ghcr.io/unmango/<name>` and `docker.io/unstoppablemango/<name>` for `linux/amd64` and `linux/arm64`.

Applications that live in their own repository publish their image from there instead.
This repository is only for wrapping software someone else wrote.

## Images

| Image                 | Wraps                                                                   |
| --------------------- | ----------------------------------------------------------------------- |
| `actions-runner`      | [`ghcr.io/actions/actions-runner`][runner], plus `nix`, `make` and `xz` |
| `coredns`             | [CoreDNS][]                                                             |
| `gitlab-operator-v2`  | [GitLab Operator][]                                                     |
| `hercules-ci-agent`   | [Hercules CI agent][], also as a `-standalone` variant carrying a store |
| `wireguard-cni-tools` | `wireguard-tools`, `iproute2`, `netcat`, coreutils, `bash`              |

## Usage

```sh
docker pull ghcr.io/unmango/actions-runner:2.337.0
docker pull docker.io/unstoppablemango/coredns:1.14.6
```

Tags are the wrapped application's version, plus `latest` and `sha-<short>` on `main`.
Pin by digest if you need immutability: a version tag is republished when the Nix closure underneath it changes.

Some images publish variants, which share a repository and differ by a tag suffix: `<version>-<variant>`, plus `<variant>` in place of `latest`.
Swapping between them is a tag change.

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

Both run as uid 1000, which must own the state volume.
Root is not an option: the agent refuses to host an effect as root.
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

<<<<<<< HEAD
`--config /etc/hercules-ci-agent/agent.json` is the default `Cmd`; no config is baked in, so mount one there or pass `--config` yourself.
JSON rather than TOML, because TOML cannot express `null` in `labels` and silently drops subtables.
The config supplies `baseDirectory`, and the operator installs `cluster-join-token.key` and `binary-caches.json` under its `secrets` directory.
Leave `baseDirectory` at `/var/lib/hercules-ci-agent` or mount the volume at whatever path you set it to.
The agent writes work directories and `secretState/session.key` under `baseDirectory` and nowhere else, so a mismatch leaves that state on the container's writable layer, where it is lost on the next `docker run`.

The image runs as uid 1000, which must own the state volume.
Root is not an option: the agent refuses to host an effect as root.
The image ships `/var/lib/hercules-ci-agent` and `/tmp` owned by uid 1000, so Docker seeds a fresh named volume with that ownership.
A bind mount keeps the host directory's ownership instead, so `chown 1000:1000` it first.
=======
#### Standalone

Carries a registered store, so there is no `/nix` mount:

```sh
docker run \
  -v ./agent.json:/etc/hercules-ci-agent/agent.json:ro \
  -v hercules-state:/var/lib/hercules-ci-agent \
  ghcr.io/unmango/hercules-ci-agent:0.10.8-standalone
```

Set `nixUserIsTrusted = true` in the config: there is no daemon to refuse anything, and it saves materializing a full `.drv` closure on every build.

The store lives in the container's writable layer and is discarded with the container.
Mount a volume at `/nix` to keep it, accepting that the runtime seeds the volume from the image on first use.
Nothing garbage-collects it either, because the agent registers no GC roots, so `nix` is on `PATH` for `nix store gc`.
>>>>>>> 0b0b8e0 (feat(ci): add variant support for sharing image repositories)

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

Add an `images/<name>/base.nix` holding the registry coordinates, then run `make manifest-<name>` to pin the base image's per-architecture manifests and configs.

Two things to know:

- `pullImageFromManifest` takes a single-architecture manifest, not a multi-arch index, so each system pins its own file.
- **nix2container replaces the base image's config rather than merging into it.** Anything not restated in your `config` is lost, including `PATH`. This is why the base config is pinned too and inherited explicitly. See `images/actions-runner/default.nix`.

A third trap, if you add tools on top of a base image: link them into `/usr/local` with `buildEnv`'s `extraPrefix`, never into `/`.
A layer containing a real `./bin` directory replaces the base image's `/bin -> usr/bin` symlink and hides everything the base image resolves through it.

If the image ships `nix` itself, set `initializeNixDatabase = true` so the store paths it carries are registered, and set `nixUid`/`nixGid` to the user that will build in that store.

Renovate bumps `version` in `base.nix` but cannot regenerate the pinned files, so `.github/workflows/update-manifests.yml` does it on Renovate branches and CI fails on drift.

[nix2container]: https://github.com/nlewo/nix2container
[runner]: https://github.com/actions/runner
[CoreDNS]: https://coredns.io
[GitLab Operator]: https://gitlab.com/gitlab-org/cloud-native/gitlab-operator
[Hercules CI agent]: https://hercules-ci.com
