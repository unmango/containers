# Base image coordinates, kept as data so scripts/update-manifest.sh can read
# them with `nix eval --json --file` instead of grepping Nix source.
#
# nix2container's pullImageFromManifest resolves layer blobs through
# `skopeo layers "<registryUrl>/<imageName>:<version>" <digest>`, i.e. by tag
# rather than by digest. If upstream ever retags or deletes this version the
# fetch breaks even though the pinned digests remain valid.
{
  registryUrl = "ghcr.io";
  imageName = "actions/actions-runner";
  # renovate: datasource=docker depName=ghcr.io/actions/actions-runner
  version = "2.337.0";
}
