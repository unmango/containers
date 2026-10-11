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
  lib,
  mkImage,
  notsystemd,
  runCommand,
  unifi-os-server,
  writeTextDir,
}:
let
  # Every unit is Type=notify, and their scripts are bash.
  tools = buildEnv {
    name = "unifi-os-server-tools";
    paths = [
      bashInteractive
      coreutils
    ];
    pathsToLink = [ "/bin" ];
  };

  passwd = writeTextDir "etc/passwd" ''
    root:x:0:0::/root:/bin/bash
    nobody:x:65534:65534::/nonexistent:/usr/sbin/nologin
  '';

  group = writeTextDir "etc/group" ''
    root:x:0:
    nogroup:x:65534:
  '';

  dirs = runCommand "unifi-os-server-dirs" { } ''
    mkdir -p $out/tmp $out/run/notsystemd
  '';

  mkUosImage =
    component: unit:
    mkImage {
      name = "unifi-os-server-${component}";
      inherit (unifi-os-server) version;

      copyToRoot = [
        unifi-os-server.${component}
        tools
        cacert
        passwd
        group
        dirs
      ];

      perms = [
        {
          path = dirs;
          regex = "/tmp$";
          mode = "1777";
        }
      ];

      config = {
        Entrypoint = [
          "${lib.getExe notsystemd}"
          "run"
        ];
        Cmd = [ "/usr/lib/systemd/system/${unit}" ];
        Env = [
          "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
          "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
        ];
        # notsystemd's state directory, shared with the pod's other containers
        # and read by `notsystemd is-active` probes.
        Volumes."/run/notsystemd" = { };
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
