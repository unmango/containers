{
  buildEnv,
  cacert,
  knot-migrate,
  knot-rs,
  lib,
  mkImage,
  runCommand,
  tangled,
}:
let
  uid = 1000;
  gid = 1000;

  # knot-server refuses to start unless the scan path already exists and is
  # writable. Docker seeds a fresh named volume from the image's directory,
  # so shipping these owned by the knot user is what makes a bare
  # `-v repos:/data/repos` work without a chown.
  dataDir = runCommand "knot-data-root" { } "mkdir -p $out/data/repos $out/data/state";
in
mkImage {
  name = "knot";
  # Upstream's crate version is fixed at 2.0.0 across commits, so the source
  # date keeps each flake.lock bump on a distinct tag.
  version = "${knot-rs.version}-unstable-${lib.substring 0 8 tangled.lastModifiedDate}";

  copyToRoot = [
    (buildEnv {
      name = "knot-root";
      paths = [
        knot-migrate
        knot-rs
      ];
      pathsToLink = [ "/bin" ];
    })
    dataDir
    # reqwest verifies through the platform store, not bundled roots, and
    # fails to build its client at startup without one.
    cacert
  ];

  perms = [
    {
      path = dataDir;
      regex = "/data(/repos|/state)?$";
      mode = "0750";
      inherit uid gid;
    }
  ];

  config = {
    # Matches the uid of upstream's atcr.io/tangled.org/knot:2 image.
    User = "${toString uid}:${toString gid}";
    # No config path argument: knot-server then reads KNOT_* variables and an
    # optional /etc/knot/config.toml, where a path it is given must exist.
    Entrypoint = [ "/bin/knot-server" ];
    ExposedPorts = {
      "5555/tcp" = { };
      "2222/tcp" = { };
    };
  };
}
