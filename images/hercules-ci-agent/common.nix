# Everything both agent images share. The two modes are ./default.nix and
# ./standalone.nix, which differ only in whether the image brings its own Nix
# store; read those first, they are short on purpose.
{
  cacert,
  hercules-ci-agent,
  lib,
  mkImage,
  nix2container,
  writeTextDir,
}:
let
  baseDirectory = "/var/lib/hercules-ci-agent";

  uid = 1000;
  gid = 1000;

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
{
  mkAgentImage =
    {
      # null for the plain image, a string for a variant. Drives the OCI tag
      # suffix and, through imageMeta, the moving tag CI publishes.
      variant ? null,
      # Ship a registered Nix store rather than expecting a mounted one.
      bundledStore ? false,
      # Appended to the shared /etc/nix/nix.conf.
      nixConf ? "",
      # Appended to the shared image roots.
      copyToRoot ? [ ],
    }:
    let
      roots = [
        cacert
        group
        passwd

        # The agent fatally exits at startup unless the negative narinfo cache
        # is disabled, and its own error text points at this file. On NixOS the
        # hercules-ci-agent module supplies it through `nix.extraOptions`; there
        # is no module here, so the image carries it.
        (writeTextDir "etc/nix/nix.conf" ''
          narinfo-cache-negative-ttl = 0
          ${nixConf}
        '')
      ]
      ++ copyToRoot;
    in
    mkImage {
      # Both modes publish to the same repository and are told apart by tag, so
      # this is deliberately not the images attrset key.
      name = "hercules-ci-agent";
      inherit (hercules-ci-agent) version;
      inherit variant;

      copyToRoot = roots;

      # nix2container copies a copyToRoot entry's contents to / and leaves the
      # entry's own store path out of the image, but initializeNixDatabase
      # registers its whole closure. Without this layer the shipped database
      # would claim paths that are absent, and a build depending on one of them
      # (cacert, most plausibly) would fail on a path Nix believes is valid.
      layers = lib.optional bundledStore (nix2container.buildLayer { deps = roots; });

      # Registers the store paths the image ships in /nix/var/nix/db, and gives
      # the database the agent's ids so it can write temproots and take gc.lock.
      # Without that, Nix's `auto` store resolution falls through to a daemon
      # socket that a self-contained image has no reason to provide.
      initializeNixDatabase = bundledStore;
      nixUid = uid;
      nixGid = gid;

      config = {
        # `Hercules/Effect.hs` panics with "Refusing to host effect as root
        # user", so effects are unusable unless the image defaults to an
        # unprivileged uid.
        User = "hercules-ci-agent";
        WorkingDir = baseDirectory;

        Env = [
          # The agent links Nix as a library, so libnixexpr's eval and fetcher
          # caches land under $HOME/.cache. Upstream also documents ~/.ssh as
          # where the agent's deploy key goes. The NixOS module points the
          # service user's home at baseDirectory for the same reasons.
          "HOME=${baseDirectory}"
          # Source tarballs are unpacked with `tar -xz`, which needs somewhere
          # to write. Nothing creates /tmp in a scratch image, hence the volume
          # below.
          "TMPDIR=/tmp"
          # Outbound HTTPS to hercules-ci.com, its socket endpoints, cachix.org
          # and github.com. Both names are set because the agent's own HTTP
          # client reads SSL_CERT_FILE while the linked-in Nix reads
          # NIX_SSL_CERT_FILE.
          #
          # The /etc path, not `${cacert}`. nix2container copies a copyToRoot
          # entry's *contents* to / and leaves its store path out of the image,
          # so a store-path reference here resolves only when a host /nix
          # happens to be mounted and happens to have that exact cacert.
          "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
          "NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
        ];

        # bin/, never libexec/. The bin entry is the wrapper that puts tar, gzip,
        # git, ssh and crun on PATH; libexec/ is the bare binary with none of
        # them.
        Entrypoint = [ "${hercules-ci-agent}/bin/hercules-ci-agent" ];

        # `--config FILE` is a required option with no default and no search
        # path, so an image without this exits on a usage error. No config is
        # baked in: the operator mounts one. JSON rather than TOML because TOML
        # cannot express `null` in `labels` and silently drops subtables.
        Cmd = [
          "--config"
          "/etc/hercules-ci-agent/agent.json"
        ];

        # The agent creates work/, work/secure (0700) and secretState/session.key
        # under baseDirectory, and reads secrets/cluster-join-token.key from it.
        #
        # /nix is deliberately absent even in the bundled-store mode: an
        # emptyDir mounted there would mask the store the image ships.
        Volumes = {
          ${baseDirectory} = { };
          "/tmp" = { };
        };
      };
    };
}
