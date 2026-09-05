{ runCommand, skopeo-nix2container }:
# Converts a nix2container image into a docker-archive tarball.
#
# A nix2container output is an `image.json` descriptor, not a tarball. NixOS'
# `services.kubernetes.kubelet.seedDockerImages` cats the store path straight
# into `ctr image import`, so it needs a real archive. Every layer blob is
# already a store path and the customization layer is generated on the fly, so
# this needs no network.
image:
runCommand "${image.imageName}-${image.imageTag}.tar"
  {
    nativeBuildInputs = [ skopeo-nix2container ];
    inherit (image) meta;
    passthru = { inherit (image) imageName imageTag; };
  }
  ''
    # containers/image stages big blobs in /var/tmp, which does not exist in
    # the build sandbox. --tmpdir sets BigFilesTemporaryDir; TMPDIR alone is
    # not enough for this code path.
    skopeo --insecure-policy --tmpdir "$NIX_BUILD_TOP" copy \
      "nix:${image}" \
      "docker-archive:$out:${image.imageName}:${image.imageTag}"
  ''
