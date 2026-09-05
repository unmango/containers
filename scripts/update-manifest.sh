#!/usr/bin/env bash
# Regenerate the pinned per-architecture base image manifests for one image.
#
# nix2container's pullImageFromManifest takes a single-architecture manifest,
# not a multi-arch index, so each system needs its own pinned file. Renovate
# bumps `version` in base.nix but cannot regenerate these, which is why CI
# checks them for drift.
set -euo pipefail

name="${1:?usage: update-manifest.sh <image>}"
dir="images/${name}"

if [ ! -f "${dir}/base.nix" ]; then
  echo "${name}: no base.nix, nothing to pin" >&2
  exit 0
fi

base="$(nix eval --json --file "${dir}/base.nix")"
registry="$(jq -r '.registryUrl' <<<"${base}")"
image="$(jq -r '.imageName' <<<"${base}")"
version="$(jq -r '.version' <<<"${base}")"

raw="$(skopeo inspect --raw "docker://${registry}/${image}:${version}")"

for pair in 'x86_64-linux amd64' 'aarch64-linux arm64'; do
  read -r system arch <<<"${pair}"
  out="${dir}/manifest-${system}.json"
  cfg="${dir}/config-${system}.json"
  ref="docker://${registry}/${image}:${version}"

  if jq -e 'has("manifests")' >/dev/null <<<"${raw}"; then
    digest="$(jq -r --arg a "${arch}" \
      '.manifests[] | select(.platform.os == "linux" and .platform.architecture == $a) | .digest' \
      <<<"${raw}")"

    if [ -z "${digest}" ]; then
      echo "${name}: no linux/${arch} manifest in ${image}:${version}" >&2
      exit 1
    fi

    ref="docker://${registry}/${image}@${digest}"
    manifest="$(skopeo inspect --raw "${ref}")"
  else
    # Upstream published a plain manifest rather than an index, so it describes
    # exactly one architecture. The check below decides whether it is this one.
    manifest="${raw}"
  fi

  # nix2container replaces the base image's config rather than merging into
  # it, so the config is pinned too and the derivation inherits from it
  # explicitly. Without this the image silently loses the base image's PATH.
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

  printf '%s' "${manifest}" >"${out}"
  jq --sort-keys . <<<"${config}" >"${cfg}"

  echo "${name}: pinned ${system} -> ${out}, ${cfg}"
done
