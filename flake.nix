{
  description = "OCI images for third-party applications, built with Nix";

  nixConfig = {
    extra-substituters = [
      "https://unstoppablemango.cachix.org"
    ];
    extra-trusted-public-keys = [
      "unstoppablemango.cachix.org-1:m7uEI6X1Ov8DyFWJQX4WsRFRWFuzRW5c/Xms8ZaP74U="
    ];
  };

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    systems.url = "github:nix-systems/triplet";

    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };

    nix2container = {
      url = "github:nlewo/nix2container";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Source of gitlab-operator-v2, which is not in nixpkgs. Only the package is
    # used; the images that used to live there are built here instead.
    pkgs = {
      url = "github:unmango/pkgs";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.systems.follows = "systems";
      inputs.flake-parts.follows = "flake-parts";
      inputs.nix2container.follows = "nix2container";
      inputs.treefmt-nix.follows = "treefmt-nix";
    };

    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = import inputs.systems;

      imports = with inputs; [
        treefmt-nix.flakeModule
        ./images
      ];

      perSystem =
        { inputs', pkgs, ... }:
        {
          devShells.default = pkgs.mkShellNoCC {
            packages = [
              pkgs.gh
              pkgs.gnumake
              pkgs.jq
              pkgs.nixfmt
              # `copyTo` and friends shell out to this skopeo, which understands
              # nix2container's `nix:` transport. Plain nixpkgs skopeo does not.
              inputs'.nix2container.packages.skopeo-nix2container
            ];
          };

          treefmt = {
            programs = {
              actionlint.enable = true;
              deadnix.enable = true;
              nixfmt.enable = true;
              prettier.enable = true;
              shfmt.enable = true;
              statix.enable = true;
            };

            # Pinned base manifests and configs are byte-for-byte what the
            # registry served. Reformatting them would make the CI drift check
            # compare against prettier's output rather than skopeo's.
            settings.global.excludes = [
              "images/*/manifest-*.json"
              "images/*/config-*.json"
            ];
          };
        };
    };
}
