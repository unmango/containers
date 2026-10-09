{
  bashInteractive,
  buildEnv,
  cacert,
  coreutils,
  git,
  gnutar,
  gzip,
  iana-etc,
  lib,
  mkImage,
  nix,
  nix2container,
  nixery,
  pkgs,
  runCommand,
  writeTextDir,
}:
let
  # Upstream's default.nix is written to build inside or outside TVL's depot,
  # and outside it takes nothing but a package set. It returns the server, the
  # nixery-prepare-image wrapper that the server shells out to, and an image of
  # its own built with dockerTools; only the first two are used.
  upstream = import nixery { inherit pkgs; };

  uid = 1000;
  gid = 1000;

  # git resolves the running uid with getpwuid when it fetches a package set,
  # and nix wants a home directory. Upstream's launch script appends these to
  # /etc/passwd at startup, which needs root and a writable root filesystem;
  # shipping them here needs neither.
  passwd = writeTextDir "etc/passwd" ''
    root:x:0:0::/root:/noshell
    nixery:x:${toString uid}:${toString gid}::/var/lib/nixery:/noshell
  '';

  group = writeTextDir "etc/group" ''
    root:x:0:
    nixery:x:${toString gid}:
  '';

  nixConf = writeTextDir "etc/nix/nix.conf" ''
    # Nothing here runs as root and there is no daemon, so builds run as the
    # nixery user. There is no build-users-group to drop to, and the sandbox is
    # unavailable. Upstream's launch script turns the sandbox off for the same
    # reason.
    build-users-group =
    sandbox = false
  '';

  # /tmp is where nix unpacks the package set tarball and builds, and
  # /var/lib/nixery is HOME, where nix keeps its fetcher cache. STORAGE_PATH
  # defaults to a directory under it, so the filesystem backend works without
  # a volume, if only for the life of the container.
  dirs = runCommand "nixery-dirs" { } ''
    mkdir -p $out/tmp $out/var/lib/nixery/storage
  '';

  dirPerms = [
    {
      path = dirs;
      regex = "/tmp$";
      mode = "1777";
      inherit uid gid;
      uname = "nixery";
      gname = "nixery";
    }
    {
      path = dirs;
      regex = "/var/lib/nixery(/storage)?$";
      mode = "0755";
      inherit uid gid;
      uname = "nixery";
      gname = "nixery";
    }
  ];

  # A real /bin is correct here: this is a scratch image, so there is no base
  # image `/bin -> usr/bin` symlink to shadow. nix-build is what
  # nixery-prepare-image runs, git is what fetches a NIXERY_PKGS_REPO, and the
  # rest is enough to debug with `kubectl exec`.
  tools = buildEnv {
    name = "nixery-tools";
    paths = [
      bashInteractive
      coreutils
      git
      gnutar
      gzip
      nix
      upstream.nixery-prepare-image
    ];
    pathsToLink = [ "/bin" ];
  };

  # cacert for nix and git, and iana-etc for /etc/protocols and /etc/services,
  # which Go's net package reads. Joined on /etc because copied to / whole they
  # collide on nix-support/setup-hook.
  etc = buildEnv {
    name = "nixery-etc";
    paths = [
      cacert
      iana-etc
    ];
    pathsToLink = [ "/etc" ];
  };

  roots = [
    dirs
    etc
    group
    nixConf
    passwd
    tools
  ];
in
mkImage {
  name = "nixery";
  # Upstream tags no releases and builds with a version of "depot", so the
  # mirror's commit date keeps each flake.lock bump on a distinct tag.
  version = "0-unstable-${lib.substring 0 8 nixery.lastModifiedDate}";

  copyToRoot = roots;
  perms = dirPerms;

  # nix2container copies a copyToRoot entry's contents to / and leaves the
  # entry's own store path out of the image, but initializeNixDatabase registers
  # its whole closure. This layer materializes that closure, so the database
  # claims only paths that are there and nixery-prepare-image finds its nix.
  layers = [ (nix2container.buildLayer { deps = roots; }) ];

  # Registers the shipped store and gives the database to the nixery user, so
  # nix-build finds a local store it can write rather than falling through to a
  # daemon socket.
  initializeNixDatabase = true;
  nixUid = uid;
  nixGid = gid;

  config = {
    User = "nixery";
    WorkingDir = "/var/lib/nixery";

    Env = [
      "HOME=/var/lib/nixery"
      "TMPDIR=/tmp"
      "PATH=/bin"
      # The /etc path, not `${cacert}`, for the reason in AGENTS.md.
      "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
      "NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
      # The server exits without a port, a package source, or a storage
      # backend. These defaults serve nixos-unstable from the container's own
      # filesystem; override any of them at run time.
      "PORT=8080"
      "NIXERY_CHANNEL=nixos-unstable"
      "NIXERY_STORAGE_BACKEND=filesystem"
      "STORAGE_PATH=/var/lib/nixery/storage"
    ];

    # bin/server is upstream's wrapper, which puts nixery-prepare-image on PATH.
    Entrypoint = [ "${upstream.nixery}/bin/server" ];

    ExposedPorts."8080/tcp" = { };

    # /nix is deliberately absent: a volume mounted there would mask the store
    # the image ships.
    Volumes = {
      "/var/lib/nixery/storage" = { };
      "/tmp" = { };
    };
  };
}
