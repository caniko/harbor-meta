{nixpkgs}: let
  nixLib = nixpkgs.lib;
in {
  opencode = import ./opencode.nix {lib = nixLib;};
  packageTests = import ./package-tests.nix {lib = nixLib;};
  devShell = import ./shell.nix {lib = nixLib;};
  devShellTests = import ./dev-shell-tests.nix {lib = nixLib;};
  templateTests = import ./template-tests.nix {lib = nixLib;};
}
