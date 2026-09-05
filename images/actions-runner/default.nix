{
  buildEnv,
  gnumake,
  lib,
  mkImage,
  nix2container,
  stdenv,
  xz,
}:
let
  base = import ./base.nix;
  inherit (stdenv.hostPlatform) system;

  # pullImageFromManifest consumes a single-architecture manifest, but
  # ghcr.io/actions/actions-runner publishes a multi-arch index, so each system
  # pins its own. Regenerate both files with `make manifest-actions-runner`.
  manifests = {
    x86_64-linux = ./manifest-x86_64-linux.json;
    aarch64-linux = ./manifest-aarch64-linux.json;
  };

  configs = {
    x86_64-linux = ./config-x86_64-linux.json;
    aarch64-linux = ./config-aarch64-linux.json;
  };

  imageManifest =
    manifests.${system} or (throw "actions-runner: no pinned base manifest for ${system}");

  # nix2container REPLACES the base image's config rather than merging into it,
  # so anything not restated here is lost. Dropping the base PATH alone breaks
  # every tool the runner shells out to.
  baseConfig =
    (lib.importJSON (
      configs.${system} or (throw "actions-runner: no pinned base config for ${system}")
    )).config;

  # Link into /usr/local, not /. A layer containing a real ./bin directory
  # replaces the base image's `/bin -> usr/bin` symlink and hides everything the
  # base image resolves through it, including git and node.
  tools = buildEnv {
    name = "actions-runner-tools";
    paths = [
      gnumake
      xz
    ];
    pathsToLink = [ "/bin" ];
    extraPrefix = "/usr/local";
  };
in
mkImage {
  name = "actions-runner";
  inherit (base) version;

  fromImage = nix2container.pullImageFromManifest {
    inherit (base) registryUrl imageName;
    inherit imageManifest;
    imageTag = base.version;
  };

  copyToRoot = [ tools ];

  config = baseConfig // {
    # OCI config keys are capitalized. unmango/pkgs' github-runner image used
    # lowercase `user`/`entrypoint`, which runtimes silently ignore.
    User = "runner";
    WorkingDir = "/home/runner";
    # cachix/cachix-action reads $USER, which the base image does not set.
    Env = baseConfig.Env ++ [ "USER=runner" ];
    Entrypoint = [ "/home/runner/run.sh" ];
    # Cleared so the base image's `Cmd = [ "/bin/bash" ]` is not inherited and
    # passed to run.sh as an argument.
    Cmd = [ ];
  };
}
