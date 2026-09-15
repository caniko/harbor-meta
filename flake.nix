{
  description = "Shared harbor helpers for editor and agent tooling";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Suite-only nightly rustfmt: simit-shaped modules inject the nightly-only
    # skip_children flag, so the treefmt-scope regression suite cannot run on
    # stable rustfmt. Pinned by date (overlays only ever add manifests).
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
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
            treefmt-scope = import ./checks/treefmt-scope.nix {
              inherit pkgs system nixpkgs;
              lib = self.lib;
              inherit (inputs) treefmt-nix rust-overlay;
            };
          };

        formatter = treefmt.config.build.wrapper;
      };
    };
}
