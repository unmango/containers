{ nix2container }:
# Wrapper around nix2container.buildImage that makes `version` the single
# source of truth for both the OCI tag and `meta.version`.
#
# nix2container defaults `imageTag` to a hash of the image's output, which
# changes on every rebuild. Consumers that interpolate `${imageName}:${imageTag}`
# into a manifest would then churn on every unrelated closure change, so the tag
# is always pinned to the version instead.
{
  name,
  version,
  meta ? { },
  ...
}@args:
nix2container.buildImage (
  removeAttrs args [ "version" ]
  // {
    inherit name;
    tag = version;
    meta = meta // {
      inherit version;
    };
  }
)
