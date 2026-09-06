{
  callPackage,
  mkImage,
  nix2container,
}:
# ── MODE: HOST STORE ────────────────────────────────────────────────────────
# Carries the agent closure and nothing else. The operator mounts the host's
# /nix, which the agent opens as a LocalStore because Nix's `auto` resolution
# finds /nix/var/nix writable.
#
# See ./standalone.nix for the mode that brings its own store, and ./common.nix
# for everything the two share.
# ────────────────────────────────────────────────────────────────────────────
#
# `mkImage` and `nix2container` are passed explicitly because the `callPackage`
# in scope inside a called package is plain `pkgs.callPackage`, which carries
# neither.
(callPackage ./common.nix { inherit mkImage nix2container; }).mkAgentImage { }
