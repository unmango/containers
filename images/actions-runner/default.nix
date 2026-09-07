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
  # pins its own. Regenerate the pins with `make manifest-actions-runner`.
  imageManifest = ./. + "/manifest-${system}.json";

  # nix2container REPLACES the base image's config rather than merging into it,
  # so anything not restated here is lost. Dropping the base PATH alone breaks
  # every tool the runner shells out to. The config is the same for every
  # architecture, which the update script checks, so one pin serves both.
  baseConfig = lib.importJSON ./config.json;

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

  # cachix/install-nix-action ends by appending the user profile's bin directory
  # to $GITHUB_PATH. It never reaches that line on this image: it finds nix at
  # /usr/local/bin, prints "Aborting: Nix is already installed" and exits
  # reporting success, so anything a job installs with `nix-env -i` lands in a
  # directory nothing looks in. cachix/cachix-action is what notices, since it
  # installs cachix and then resolves the name on PATH.
  #
  # Appended rather than prepended, so a package installed into the profile
  # cannot shadow the tools in /usr/local/bin this image exists to provide.
  # install-nix-action prepends, through $GITHUB_PATH, but it is not the one
  # carrying those tools.
  #
  # ~/.nix-profile is where nix keeps the default profile unless
  # use-xdg-base-directories is set, which nothing here sets. The XDG location
  # follows it so a job that does set it still resolves.
  nixProfileBins = [
    "/home/runner/.nix-profile/bin"
    "/home/runner/.local/state/nix/profile/bin"
  ];

  # OCI Env is a list of KEY=VALUE and runtimes disagree about which of two
  # PATH= entries wins, so the base image's entry is rewritten rather than
  # shadowed by a second one.
  envWithNixProfile = map (
    entry:
    if lib.hasPrefix "PATH=" entry then
      lib.concatStringsSep ":" ([ entry ] ++ nixProfileBins)
    else
      entry
  ) baseConfig.Env;

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
    Env = envWithNixProfile ++ [
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
