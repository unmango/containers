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
| `hercules-ci-agent`   | [Hercules CI agent][]                                                   |
| `wireguard-cni-tools` | `wireguard-tools`, `iproute2`, `netcat`, coreutils, `bash`              |

## Usage

```sh
docker pull ghcr.io/unmango/actions-runner:2.337.0
docker pull docker.io/unstoppablemango/coredns:1.14.6
```

Tags are the wrapped application's version, plus `latest` and `sha-<short>` on `main`.
Pin by digest if you need immutability: a version tag is republished when the Nix closure underneath it changes.

### `hercules-ci-agent`

The agent links Nix as a library rather than shelling out to it, so it is a Nix client and not a self-contained builder.
It needs the host's store and a reachable `nix-daemon`, an agent config, and a state directory.

```sh
docker run \
  -v /nix:/nix \
  -v ./agent.json:/etc/hercules-ci-agent/agent.json:ro \
  -v hercules-state:/var/lib/hercules-ci-agent \
  ghcr.io/unmango/hercules-ci-agent:0.10.8
```

`--config /etc/hercules-ci-agent/agent.json` is the default `Cmd`; no config is baked in, so mount one there or pass `--config` yourself.
JSON rather than TOML, because TOML cannot express `null` in `labels` and silently drops subtables.
The config supplies `baseDirectory`, and the operator installs `cluster-join-token.key` and `binary-caches.json` under its `secrets` directory.

The image runs as uid 1000, which must own the state volume.
Root is not an option: the agent refuses to host an effect as root.

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
