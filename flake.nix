{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    { self
    , nixpkgs
    , flake-utils
    ,
    }:
    flake-utils.lib.eachDefaultSystem
      (system:
      let
        pkgs = nixpkgs.legacyPackages.${system}.appendOverlays [
          self.overlays.default
        ];
      in
      {
        packages = {
          example = pkgs.callPackage ./example { };
        };

        lib = {
          inherit (pkgs) mkPnpmPackage mkPnpmWorkspace mkPnpmNodeModules mkPnpmStore;
        };

        checks = {
          nixpkgs-fmt = pkgs.runCommand "check-nixpkgs-fmt" { nativeBuildInputs = [ pkgs.nixpkgs-fmt ]; } ''
            nixpkgs-fmt --check ${./.}
            touch $out
          '';

          build-example = self.packages.${system}.example;
        };
      })
    // {
      overlays.default = final: prev: {
        inherit (prev.callPackage ./derivation.nix { })
          mkPnpmPackage mkPnpmWorkspace mkPnpmNodeModules mkPnpmStore;
      };
    };
}
