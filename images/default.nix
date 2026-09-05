{
  perSystem =
    {
      inputs',
      lib,
      pkgs,
      ...
    }:
    let
      inherit (pkgs.stdenv.hostPlatform) isLinux;

      tools = {
        inherit (inputs'.nix2container.packages) nix2container skopeo-nix2container;
        inherit (inputs'.pkgs.packages) gitlab-operator-v2;

        mkImage = import ./lib/mk-image.nix {
          inherit (inputs'.nix2container.packages) nix2container;
        };
      };

      callPackage = lib.callPackageWith (pkgs // tools);

      mkArchive = pkgs.callPackage ./lib/mk-archive.nix {
        inherit (tools) skopeo-nix2container;
      };

      images = {
        actions-runner = callPackage ./actions-runner { };
        coredns = callPackage ./coredns { };
        gitlab-operator-v2 = callPackage ./gitlab-operator-v2 { };
        hercules-ci-agent = callPackage ./hercules-ci-agent { };
        wireguard-cni-tools = callPackage ./wireguard-cni-tools { };
      };

      # Docker-archive tarballs, for consumers that need a loadable file rather
      # than a registry reference. Only built for images that have one.
      archives = lib.mapAttrs' (n: v: lib.nameValuePair "${n}-archive" (mkArchive v)) {
        inherit (images) coredns;
      };
    in
    {
      # Images are top-level packages rather than `passthru.image` on the
      # package they wrap, the way unmango/pkgs does it. `passthru` hides them
      # from `nix flake show`, from CI enumeration, and from other flakes, all
      # of which need to name an image directly.
      packages = lib.optionalAttrs isLinux (
        images
        // archives
        // {
          default = pkgs.linkFarm "unmango-containers" (
            lib.mapAttrsToList (name: path: { inherit name path; }) (images // archives)
          );

          # Re-exported so these exact store paths land in the cache. `copyTo`
          # shells out to this skopeo, and it is not in nixpkgs.
          inherit (inputs'.nix2container.packages) nix2container-bin skopeo-nix2container;
        }
      );

      # The enumeration surface CI reads, so adding an image needs no workflow
      # edit. Not `packages`, because these values are attrsets rather than
      # derivations and `nix flake check` rejects those.
      legacyPackages.imageMeta = lib.optionalAttrs isLinux (
        lib.mapAttrs (_: img: {
          inherit (img) imageName imageTag;
          inherit (img.meta) version;
        }) images
      );
    };
}
