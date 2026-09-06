{
  buildEnv,
  callPackage,
  mkImage,
  nix,
  nix2container,
}:
# ── MODE: BUNDLED STORE ─────────────────────────────────────────────────────
# Ships a registered Nix store, so the container needs no host /nix and no
# nix-daemon. That works because the agent links Nix as a library rather than
# talking to a daemon, and because it spawns its own `hercules-ci-nix-daemon`
# proxy to back the effect sandbox.
#
# The store lives in the container's writable layer and is therefore ephemeral.
# Published as `hercules-ci-agent:<version>-standalone`.
#
# See ./default.nix for the mode that uses the host's store, and ./common.nix
# for everything the two share.
# ────────────────────────────────────────────────────────────────────────────
let
  # A real /bin is correct here, as in images/wireguard-cni-tools: this is a
  # scratch image, so there is no base image `/bin -> usr/bin` symlink to
  # shadow.
  #
  # The agent never shells out to nix and does not need this to build. It is
  # here because the agent registers no gcroots, so a store that lives for the
  # life of the container grows without bound and the operator needs a way to
  # run `nix store gc`.
  nixTools = buildEnv {
    name = "hercules-ci-agent-standalone-tools";
    paths = [ nix ];
    pathsToLink = [ "/bin" ];
  };
in
(callPackage ./common.nix { inherit mkImage nix2container; }).mkAgentImage {
  variant = "standalone";
  bundledStore = true;
  copyToRoot = [ nixTools ];

  nixConf = ''
    # Nothing here runs as root and there is no daemon, so builds run as the
    # agent user. There is no build-users-group to drop to, and the sandbox is
    # unavailable.
    build-users-group =
    sandbox = false
  '';
}
