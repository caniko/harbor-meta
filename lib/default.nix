{nixpkgs}: let
  nixLib = nixpkgs.lib;
in {
  opencode = import ./opencode.nix {lib = nixLib;};
}
