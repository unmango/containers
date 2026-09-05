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

eval "$(nix eval --json --file "${dir}/base.nix" |
  jq -r '@sh "registry=\(.registryUrl) image=\(.imageName) version=\(.version)"')"

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
    skopeo inspect --raw "${ref}" >"${out}"
  else
    # Single-architecture upstream: the same manifest serves every system.
    printf '%s' "${raw}" >"${out}"
  fi

  # nix2container replaces the base image's config rather than merging into
  # it, so the config is pinned too and the derivation inherits from it
  # explicitly. Without this the image silently loses the base image's PATH.
  skopeo inspect --config "${ref}" | jq --sort-keys . >"${cfg}"

  echo "${name}: pinned ${system} -> ${out}, ${cfg}"
done
