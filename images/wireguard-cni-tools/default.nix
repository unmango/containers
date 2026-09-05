{
  bash,
  buildEnv,
  iproute2,
  mkImage,
  netcat,
  uutils-coreutils-noprefix,
  wireguard-tools,
}:
mkImage {
  name = "wireguard-cni-tools";
  # No upstream application of its own, so it tracks the tool that defines it.
  inherit (wireguard-tools) version;

  # A real /bin is correct here: this is a scratch image, so there is no base
  # image `/bin -> usr/bin` symlink to shadow.
  copyToRoot = buildEnv {
    name = "wireguard-cni-tools-root";
    paths = [
      bash
      iproute2
      netcat
      uutils-coreutils-noprefix
      wireguard-tools
    ];
    pathsToLink = [ "/bin" ];
  };

  config.Entrypoint = [ "/bin/bash" ];
}
