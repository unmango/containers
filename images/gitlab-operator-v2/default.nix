{
  cacert,
  gitlab-operator-v2,
  mkImage,
}:
mkImage {
  name = "gitlab-operator-v2";
  inherit (gitlab-operator-v2) version;

  copyToRoot = [ cacert ];

  config = {
    User = "1001";
    Entrypoint = [ "${gitlab-operator-v2}/bin/manager" ];
  };
}
