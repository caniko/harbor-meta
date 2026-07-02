{
  description = "Shared harbor helpers for editor and agent tooling";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = {
    self,
    nixpkgs,
    flake-utils,
    ...
  }: let
    lib = import ./lib {inherit nixpkgs;};
  in
    {
      inherit lib;
    }
    // flake-utils.lib.eachDefaultSystem (system: let
      pkgs = import nixpkgs {inherit system;};
      harborOpencode = import ./nix/harbor-opencode.nix {inherit pkgs lib;};
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

      checks = import ./checks {inherit pkgs lib harborOpencode;};

      formatter = pkgs.alejandra;
    });
}
