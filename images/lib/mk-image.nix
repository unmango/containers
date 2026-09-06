{ nix2container }:
# Wrapper around nix2container.buildImage that makes `version` the single
# source of truth for both the OCI tag and `meta.version`.
#
# nix2container defaults `imageTag` to a hash of the image's output, which
# changes on every rebuild. Consumers that interpolate `${imageName}:${imageTag}`
# into a manifest would then churn on every unrelated closure change, so the tag
# is always pinned to the version instead.
#
# `variant` suffixes the tag so two builds of the same application can share one
# repository and be told apart by tag, the way `node:22` and `node:22-alpine`
# are. It suffixes the tag rather than the version because `meta.version` is
# what Renovate and consumers read as the upstream version, and because CI
# derives the moving tag (`latest`, or the variant's own name) from it.
{
  name,
  version,
  variant ? null,
  meta ? { },
  ...
}@args:
nix2container.buildImage (
  removeAttrs args [
    "version"
    "variant"
  ]
  // {
    inherit name;
    tag = if variant == null then version else "${version}-${variant}";
    meta = meta // {
      inherit version variant;
    };
  }
)
