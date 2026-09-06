{
  buildEnv,
  gnumake,
  lib,
  mkImage,
  nix,
  nix2container,
  stdenv,
  writeTextDir,
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
      nix
      xz
    ];
    pathsToLink = [ "/bin" ];
    extraPrefix = "/usr/local";
  };

  # Settings every job wants, so no workflow has to pass them. Anything
  # deployment-specific, a substituter above all, arrives as NIX_CONFIG at
  # runtime, which nix merges on top of this file.
  nixConf = writeTextDir "etc/nix/nix.conf" ''
    experimental-features = nix-command flakes pipe-operators
    # Nothing here runs as root and there is no daemon, so builds run as the
    # invoking user and the sandbox is unavailable.
    sandbox = false
  '';

  # The base image's runner user, which owns the nix database so it can build
  # in the store this image ships.
  runnerUid = 1001;
  runnerGid = 1001;
in
mkImage {
  name = "actions-runner";
  inherit (base) version;

  fromImage = nix2container.pullImageFromManifest {
    inherit (base) registryUrl imageName;
    inherit imageManifest;
    imageTag = base.version;
  };

  copyToRoot = [
    tools
    nixConf
  ];

  # Registers the store paths this image ships in /nix/var/nix/db, which is what
  # makes the baked nix usable instead of a pile of files nix does not know
  # about. Consumers can then skip cachix/install-nix-action.
  #
  # Unlike dockerTools' includeNixDB, which writes the database 0600 root and
  # needs a chmod pass afterwards, nix2container applies mode 0755 plus these
  # ids to the whole database path.
  #
  # The database is built from the closure of `copyToRoot`, but nix2container
  # rewrites the top-level `copyToRoot` paths to `/` rather than shipping them
  # in the store. `tools` and `nixConf` are therefore registered without being
  # present, so `nix-store --verify` reports them and their gcroot symlinks
  # dangle. Their closures are shipped and nothing references those two paths,
  # so builds inside the image are unaffected. nlewo/nix2container#194 is the
  # upstream fix, unmerged. Adding them as `layers` deps is not a workaround:
  # `buildLayer` skips any store path already belonging to a listed layer, so
  # `tools` would never reach /usr/local.
  initializeNixDatabase = true;
  nixUid = runnerUid;
  nixGid = runnerGid;

  config = baseConfig // {
    # OCI config keys are capitalized. unmango/pkgs' github-runner image used
    # lowercase `user`/`entrypoint`, which runtimes silently ignore.
    User = "runner";
    WorkingDir = "/home/runner";
    Env = baseConfig.Env ++ [
      # cachix/cachix-action reads $USER, which the base image does not set.
      "USER=runner"
      # The base image is Ubuntu, so nix reaches substituters through its CA
      # bundle rather than a store path of its own.
      "NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt"
    ];
    Entrypoint = [ "/home/runner/run.sh" ];
    # Cleared so the base image's `Cmd = [ "/bin/bash" ]` is not inherited and
    # passed to run.sh as an argument.
    Cmd = [ ];
  };
}
