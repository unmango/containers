#!/usr/bin/env bash
# Regenerate the pinned base image manifests and config for one image.
#
# nix2container's pullImageFromManifest takes a single-architecture manifest,
# not a multi-arch index, so each system needs its own pinned file. Renovate
# bumps `version` in base.nix but cannot regenerate these, which is why CI
# checks them for drift.
set -euo pipefail

name="${1:?usage: update-manifest.sh <image>}"
dir="images/${name}"

base="$(nix eval --json --file "${dir}/base.nix")"
registry="$(jq -r '.registryUrl' <<<"${base}")"
image="$(jq -r '.imageName' <<<"${base}")"
version="$(jq -r '.version' <<<"${base}")"

tagref="docker://${registry}/${image}:${version}"
raw="$(skopeo inspect --raw "${tagref}")"
# A plain manifest has no per-architecture entries to pin by, so it is pinned
# by its own digest instead. Every inspection below then names immutable bytes,
# even if the tag moves partway through.
tag_digest="$(skopeo inspect --format '{{.Digest}}' "${tagref}")"
pinned=""

for pair in 'x86_64-linux amd64' 'aarch64-linux arm64'; do
  read -r system arch <<<"${pair}"
  out="${dir}/manifest-${system}.json"

  # An index yields the digest of its linux/<arch> entry. A plain manifest
  # yields nothing, so it is inspected as a whole and the architecture check
  # below decides whether it is this one.
  digest="$(jq -r --arg a "${arch}" \
    '.manifests[]? | select(.platform.os == "linux" and .platform.architecture == $a) | .digest' \
    <<<"${raw}")"
  ref="docker://${registry}/${image}@${digest:-${tag_digest}}"

  manifest="$(skopeo inspect --raw "${ref}")"
  config="$(skopeo inspect --config "${ref}")"

  # pullImageFromManifest trusts whichever manifest it is handed; it does not
  # check the platform. Pinning one under the wrong system would build an image
  # of foreign layers that only fails when something runs it. Checked before
  # anything is written, so a rejected image leaves no half-updated pins.
  upstream_arch="$(jq -r '.architecture' <<<"${config}")"
  if [ "${upstream_arch}" != "${arch}" ]; then
    echo "${name}: ${image}:${version} has no linux/${arch}, got ${upstream_arch}" >&2
    exit 1
  fi

  # nix2container replaces the base image's config rather than merging into
  # it, so the config is pinned too and the derivation inherits from it
  # explicitly. One file serves every system, so the architectures must agree.
  cfg="$(jq --sort-keys '.config' <<<"${config}")"
  if [ -n "${pinned}" ] && [ "${pinned}" != "${cfg}" ]; then
    echo "${name}: ${image}:${version} config differs between architectures" >&2
    exit 1
  fi
  pinned="${cfg}"

  printf '%s' "${manifest}" >"${out}"
  echo "${name}: pinned ${system} -> ${out}"
done

printf '%s\n' "${pinned}" >"${dir}/config.json"
echo "${name}: pinned config -> ${dir}/config.json"
