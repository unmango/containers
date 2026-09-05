{ hercules-ci-agent, mkImage }:
mkImage {
  name = "hercules-ci-agent";
  inherit (hercules-ci-agent) version;

  config.Entrypoint = [ "${hercules-ci-agent}/bin/hercules-ci-agent" ];
}
