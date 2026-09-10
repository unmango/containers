{ coredns, mkImage }:
mkImage {
  name = "coredns";
  inherit (coredns) version;

  config.Entrypoint = [ "${coredns}/bin/coredns" ];
}
