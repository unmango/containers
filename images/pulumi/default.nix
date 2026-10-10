{
  bashInteractive,
  bun,
  buildEnv,
  cacert,
  coreutils,
  iana-etc,
  mkImage,
  pulumi,
  pulumiPackages,
  runCommand,
  writeTextDir,
}:
# A Pulumi CLI image for programs whose runtime is bun, sized to serve as a
# Pulumi Kubernetes Operator workspace image (`Stack.spec.workspaceTemplate.
# spec.image`). Upstream's pulumi/pulumi images ship node, python, go and
# dotnet but not bun.
#
# The operator's workspace contract is what shapes it:
#
# - Its init containers run `sh -c` scripts with `ln` in this image, so it
#   needs a shell and coreutils, not only `pulumi`.
# - The `restricted` security profile runs every container as 1000:1000 and
#   sets no HOME, so the image names that user and gives it a writable home.
#   Pulumi keeps plugins and credentials under ~/.pulumi, and bun its install
#   cache under ~/.bun.
# - The agent and tini are copied in from the operator's own image, so neither
#   belongs here.
#
# Provider plugins are left out on purpose. `pulumi install` downloads exactly
# the versions a program's SDKs ask for, whereas a plugin on PATH is used
# silently whatever version it is.
let
  uid = 1000;
  gid = 1000;

  passwd = writeTextDir "etc/passwd" ''
    root:x:0:0::/root:/noshell
    pulumi:x:${toString uid}:${toString gid}::/home/pulumi:/bin/bash
  '';

  group = writeTextDir "etc/group" ''
    root:x:0:
    pulumi:x:${toString gid}:
  '';

  dirs = runCommand "pulumi-dirs" { } ''
    mkdir -p $out/tmp $out/home/pulumi
  '';

  dirPerms = [
    {
      path = dirs;
      regex = "/tmp$";
      mode = "1777";
      inherit uid gid;
      uname = "pulumi";
      gname = "pulumi";
    }
    {
      path = dirs;
      regex = "/home/pulumi$";
      mode = "0755";
      inherit uid gid;
      uname = "pulumi";
      gname = "pulumi";
    }
  ];

  # A real /bin is correct here: this is a scratch image, so there is no base
  # image `/bin -> usr/bin` symlink to shadow. pulumi-bun carries both the bun
  # and nodejs language hosts, and pulumi finds them on PATH.
  tools = buildEnv {
    name = "pulumi-tools";
    paths = [
      bashInteractive
      bun
      coreutils
      pulumi
      pulumiPackages.pulumi-bun
    ];
    pathsToLink = [ "/bin" ];
  };

  # cacert for the backend, the registry and plugin downloads, and iana-etc for
  # /etc/protocols and /etc/services, which Go's net package reads. Joined on
  # /etc because copied to / whole they collide on nix-support/setup-hook.
  etc = buildEnv {
    name = "pulumi-etc";
    paths = [
      cacert
      iana-etc
    ];
    pathsToLink = [ "/etc" ];
  };
in
mkImage {
  name = "pulumi";
  inherit (pulumi) version;
  variant = "bun";

  copyToRoot = [
    dirs
    etc
    group
    passwd
    tools
  ];
  perms = dirPerms;

  config = {
    User = "${toString uid}:${toString gid}";
    WorkingDir = "/home/pulumi";

    Env = [
      "HOME=/home/pulumi"
      "TMPDIR=/tmp"
      "PATH=/bin"
      # The /etc path, not `${cacert}`, for the reason in AGENTS.md.
      "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
      # Nothing interactive runs here, and the update check is a network call
      # on every command.
      "PULUMI_SKIP_UPDATE_CHECK=true"
    ];

    Entrypoint = [ "/bin/pulumi" ];
  };
}
