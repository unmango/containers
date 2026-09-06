{
  cacert,
  hercules-ci-agent,
  mkImage,
  writeTextDir,
}:
let
  baseDirectory = "/var/lib/hercules-ci-agent";

  uid = 1000;
  gid = 1000;

  # The agent fatally exits at startup unless the negative narinfo cache is
  # disabled, and its own error text points at this file. On NixOS the
  # hercules-ci-agent module supplies it through `nix.extraOptions`; there is no
  # module here, so the image carries it.
  nixConf = writeTextDir "etc/nix/nix.conf" ''
    narinfo-cache-negative-ttl = 0
  '';

  # git and ssh, both on the PATH the nixpkgs wrapper bakes into the agent and
  # both used to fetch repositories, resolve the running uid with getpwuid. A
  # scratch image has no passwd database for that to find.
  passwd = writeTextDir "etc/passwd" ''
    root:x:0:0::/root:/noshell
    hercules-ci-agent:x:${toString uid}:${toString gid}::${baseDirectory}:/noshell
  '';

  group = writeTextDir "etc/group" ''
    root:x:0:
    hercules-ci-agent:x:${toString gid}:
  '';
in
mkImage {
  name = "hercules-ci-agent";
  inherit (hercules-ci-agent) version;

  copyToRoot = [
    cacert
    group
    nixConf
    passwd
  ];

  config = {
    # `Hercules/Effect.hs` panics with "Refusing to host effect as root user",
    # so effects are unusable unless the image defaults to an unprivileged uid.
    User = "hercules-ci-agent";
    WorkingDir = baseDirectory;

    Env = [
      # The agent links Nix as a library, so libnixexpr's eval and fetcher
      # caches land under $HOME/.cache. Upstream also documents ~/.ssh as where
      # the agent's deploy key goes. The NixOS module points the service user's
      # home at baseDirectory for the same reasons.
      "HOME=${baseDirectory}"
      # Source tarballs are unpacked with `tar -xz`, which needs somewhere to
      # write. Nothing creates /tmp in a scratch image, hence the volume below.
      "TMPDIR=/tmp"
      # Outbound HTTPS to hercules-ci.com, its socket endpoints, cachix.org and
      # github.com. Both names are set because the agent's own HTTP client reads
      # SSL_CERT_FILE while the linked-in Nix reads NIX_SSL_CERT_FILE.
      "SSL_CERT_FILE=${cacert}/etc/ssl/certs/ca-bundle.crt"
      "NIX_SSL_CERT_FILE=${cacert}/etc/ssl/certs/ca-bundle.crt"
    ];

    # bin/, never libexec/. The bin entry is the wrapper that puts tar, gzip,
    # git, ssh and crun on PATH; libexec/ is the bare binary with none of them.
    Entrypoint = [ "${hercules-ci-agent}/bin/hercules-ci-agent" ];

    # `--config FILE` is a required option with no default and no search path,
    # so an image without this exits on a usage error. No config is baked in:
    # the operator mounts one. JSON rather than TOML because TOML cannot express
    # `null` in `labels` and silently drops subtables.
    Cmd = [
      "--config"
      "/etc/hercules-ci-agent/agent.json"
    ];

    # The agent creates work/, work/secure (0700) and secretState/session.key
    # under baseDirectory, and reads secrets/cluster-join-token.key from it.
    Volumes = {
      ${baseDirectory} = { };
      "/tmp" = { };
    };
  };
}
