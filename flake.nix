{
  description = "Shared harbor helpers for editor and agent tooling";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs @ {
    flake-parts,
    self,
    nixpkgs,
    ...
  }:
    flake-parts.lib.mkFlake {inherit inputs;} {
      systems = ["x86_64-linux" "aarch64-linux"];

      flake = let
        lib = import ./lib {inherit nixpkgs;};
      in {
        inherit lib;
        treefmtModules = {
          nix = ./nix/treefmt/nix.nix;
          toml = ./nix/treefmt/toml.nix;
        };
      };

      perSystem = {
        system,
        pkgs,
        ...
      }: let
        harborOpencode = import ./nix/harbor-opencode.nix {
          inherit pkgs;
          lib = self.lib;
        };
        treefmt = inputs.treefmt-nix.lib.evalModule pkgs {
          imports = [self.treefmtModules.nix self.treefmtModules.toml];
          projectRootFile = "flake.nix";
        };
      in {
        packages = {
          harbor-opencode = harborOpencode;
          default = harborOpencode;
        };

        apps = {
          harbor-opencode = {
            type = "app";
            program = "${harborOpencode}/bin/harbor-opencode";
          };
          default = self.apps.${system}.harbor-opencode;
        };

        checks =
          (import ./checks {
            inherit pkgs nixpkgs;
            lib = self.lib;
            inherit harborOpencode;
          })
          // {
            treefmt-modules = import ./checks/treefmt.nix {
              inherit pkgs;
              inherit (inputs) treefmt-nix;
              modules = self.treefmtModules;
            };
          };

        formatter = treefmt.config.build.wrapper;
      };
    };
}
