{
  lib,
  mkImage,
  nix2container,
  nukeReferences,
  pkgsStatic,
  runCommand,
  stdenv,
  writeTextDir,
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

  # Real files under /usr/local, statically linked, referring to nothing under
  # /nix. That is what lets a consumer mount whatever they like at /nix: the
  # mount hides the store these were built from, and the tools do not care.
  #
  # buildEnv's extraPrefix is unusable here for the same reason. It fills
  # /usr/local with symlinks into the store, every one of which dangles the
  # moment something is mounted over /nix.
  #
  # /usr/local rather than /, either way. A layer containing a real ./bin
  # directory replaces the base image's `/bin -> usr/bin` symlink and hides
  # everything the base image resolves through it, including git and node.
  tools =
    runCommand "actions-runner-tools"
      {
        nativeBuildInputs = [ nukeReferences ];

        paths = [
          pkgsStatic.gnumake
          pkgsStatic.nix
          pkgsStatic.xz
        ];
      }
      ''
        mkdir -p "$out/usr/local/bin"

        # A relative symlink between two entries of one bin directory keeps
        # working once both sides are copied, so it stays a symlink rather than
        # becoming a second copy of a multi-megabyte binary. nix's dozen
        # nix-<verb> aliases and xz's are all of this shape.
        relativeLink() {
          local link
          [ -L "$1" ] || return 1
          link="$(readlink "$1")"
          [ "$link" = "''${link#/}" ]
        }

        # A shell wrapper's shebang names an interpreter in the store, which is
        # the one thing this image cannot rely on being there. Leaving it out
        # beats putting it on PATH to fail on first use. xz's xzgrep, xzdiff,
        # xzless and xzmore are these.
        shebang() {
          [ "$(head -c 2 "$1")" = '#!' ]
        }

        for path in $paths; do
          for src in "$path"/bin/*; do
            if relativeLink "$src" || shebang "$src"; then
              continue
            fi

            dest="$out/usr/local/bin/$(basename "$src")"
            cp -L "$src" "$dest"

            # A copied binary still carries, as plain strings, the store paths
            # its original was built against. That is enough for nix to call
            # them references and for nix2container to ship all 470MB of them
            # into a /nix this image otherwise leaves empty. None are
            # load-bearing: the certificate bundle comes from NIX_SSL_CERT_FILE
            # and the rest are defaults nix falls back off of silently.
            chmod +w "$dest"
            nuke-refs "$dest"
            chmod 0555 "$dest"
          done
        done

        for path in $paths; do
          for src in "$path"/bin/*; do
            if ! relativeLink "$src"; then
              continue
            fi

            link="$(readlink "$src")"

            # Dropped along with the wrapper it names, rather than left dangling.
            if [ -e "$out/usr/local/bin/$link" ]; then
              ln -s "$link" "$out/usr/local/bin/$(basename "$src")"
            fi
          done
        done
      '';

  # Settings every job wants, so no workflow has to pass them. Anything
  # deployment-specific, a substituter above all, arrives as NIX_CONFIG at
  # runtime, which nix merges on top of this file.
  nixConf = writeTextDir "etc/nix/nix.conf" ''
    experimental-features = nix-command flakes pipe-operators
    # Nothing here runs as root and there is no daemon, so builds run as the
    # invoking user and the sandbox is unavailable.
    sandbox = false
    # The default `auto` store gives up on /nix and redirects into a chroot
    # store under $HOME whenever /nix/var/nix is absent, which is the state of
    # every empty volume a consumer mounts there, and it does so with a warning
    # rather than an error. Naming the local store makes nix create that layout
    # under /nix instead, so the mount is what gets used. The image ships
    # nothing under /nix for it to conflict with.
    store = local
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
