# UniFi OS Server, one image per service, each running Ubiquiti's own unit file
# under notsystemd instead of systemd.
#
# These images are not in the `images` attrset: UniFi OS Server is unfree, so
# CI never builds them and they are never published. `make push-uos-<name>`
# pushes one from a workstation to a private ghcr.io/unmango repository, which
# the cluster pulls with an imagePullSecret. Nothing sets
# org.opencontainers.image.source, so the package is not linked to this public
# repository.
{
  bashInteractive,
  buildEnv,
  cacert,
  coreutils,
  curl,
  dpkg,
  findutils,
  gawk,
  gnugrep,
  gnused,
  jq,
  lib,
  mkImage,
  notsystemd,
  notsystemd-shims,
  postgresql_14,
  procps,
  runCommand,
  tzdata,
  unifi-os-server,
  util-linux,
  writeTextDir,
}:
let
  # What the units' scripts call. They name most of it absolutely, as
  # /bin/bash, /sbin/start-stop-daemon, /usr/bin/psql or /bin/systemctl, and
  # Debian splits those across four directories, so every tool is linked into
  # all four.
  tools = buildEnv {
    name = "unifi-os-server-tools";
    paths = [
      bashInteractive
      coreutils
      curl
      # start-stop-daemon, which every Go service's start.sh runs.
      dpkg
      findutils
      gawk
      gnugrep
      gnused
      jq
      # psql, createuser and createdb, which the init wrappers run against
      # the pod's Postgres over its Unix socket.
      postgresql_14
      procps
      # findmnt, mount, mountpoint and logger.
      util-linux
      # sudo, systemctl, systemd-run and timedatectl.
      notsystemd-shims
    ];
    pathsToLink = [ "/bin" ];
    # kill comes from coreutils, procps and util-linux alike.
    ignoreCollisions = true;
  };

  fhs = runCommand "unifi-os-server-fhs" { } ''
    for dir in bin sbin usr/bin usr/sbin; do
      mkdir -p $out/$dir
      for tool in ${tools}/bin/*; do
        ln -s "$(readlink -f "$tool")" "$out/$dir/$(basename "$tool")"
      done
    done
    mkdir -p $out/usr/share $out/var $out/tmp $out/run/notsystemd $out/var/log $out/data
    ln -s ${tzdata}/share/zoneinfo $out/usr/share/zoneinfo
    ln -s /run $out/var/run
  '';

  # The users and groups of the UniFi OS Server image, with its ids, so files
  # under /data keep their owners across the move. None of the Go units sets
  # User=: their scripts start as root and drop to these with
  # start-stop-daemon --chuid.
  users = {
    root = user 0 0 "/root";
    postgres = user 10100 104 "/var/lib/postgresql";
    unifi-core = user 998 998 "/nonexistent";
    unifi = user 997 997 "/var/lib/unifi";
    ulp-go = user 999 999 "/nonexistent";
    uid = user 991 991 "/nonexistent";
    ucs-agent = user 975 976 "/nonexistent";
    ucs-update = user 974 975 "/nonexistent";
    unifi-directory = user 979 979 "/nonexistent";
    nginx = user 125 132 "/nonexistent";
    nobody = user 65534 65534 "/nonexistent";
  };
  user = uid: gid: home: { inherit uid gid home; };

  groups = {
    root = group 0 [ ];
    ssl-cert = group 103 [
      "postgres"
      "unifi"
    ];
    postgres = group 104 [ ];
    nginx = group 132 [ ];
    unifi-core = group 998 [ ];
    unifi = group 997 [ ];
    ulp-go = group 999 [ ];
    uid = group 991 [ ];
    ucs-agent = group 976 [ "ucs-update" ];
    ucs-update = group 975 [ ];
    unifi-directory = group 979 [ ];
    nogroup = group 65534 [ ];
  };
  group = gid: members: { inherit gid members; };

  lines = f: set: lib.concatStrings (lib.mapAttrsToList (name: v: f name v + "\n") set);

  etcPasswd = lines (n: u: "${n}:x:${toString u.uid}:${toString u.gid}::${u.home}:/bin/bash") users;
  etcGroup = lines (n: g: "${n}:x:${toString g.gid}:${lib.concatStringsSep "," g.members}") groups;
  # ulp-go's and uid-agent's init grep /etc/shadow for their user too, and
  # try to restore a missing one from a copy no container has.
  etcShadow = lines (n: _: "${n}:!:::::::") users;

  accounts =
    runCommand "unifi-os-server-accounts"
      {
        passwd = etcPasswd;
        group = etcGroup;
        shadow = etcShadow;
      }
      ''
        mkdir -p $out/etc
        printf %s "$passwd" > $out/etc/passwd
        printf %s "$group" > $out/etc/group
        printf %s "$shadow" > $out/etc/shadow
      '';

  mkUosImage =
    component: unit:
    mkImage {
      name = "unifi-os-server-${component}";
      inherit (unifi-os-server) version;

      copyToRoot = [
        unifi-os-server.${component}
        fhs
        accounts
        cacert
      ];

      perms = [
        {
          path = fhs;
          regex = "/tmp$";
          mode = "1777";
        }
        {
          path = accounts;
          regex = "/etc/shadow$";
          mode = "0640";
        }
      ];

      config = {
        Entrypoint = [
          (lib.getExe notsystemd)
          "run"
        ];
        Cmd = [ "/usr/lib/systemd/system/${unit}" ];
        Env = [
          "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
          "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
        ];
        Volumes = {
          # notsystemd's state directory, shared by the pod's containers: the
          # systemctl shim and `notsystemd is-active` probes read it.
          "/run/notsystemd" = { };
          # Every service keeps its state under /data, as on a console.
          "/data" = { };
        };
      };
    };

  goServices = [
    "ulp-go"
    "uid-agent"
    "ucs-agent"
    "unifi-directory"
    "unifi-identity-update"
  ];
in
{
  core = mkUosImage "core" "unifi-core.service";
  network = mkUosImage "network" "unifi.service";
}
// lib.genAttrs goServices (name: mkUosImage name "${name}.service")
