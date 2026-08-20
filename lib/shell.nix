{lib}: rec {
  normalize = fragment: {
    packages = fragment.packages or [];
    env = fragment.env or {};
    shellHook = fragment.shellHook or "";
  };

  merge = fragments:
    builtins.foldl' (
      acc: fragment: let
        spec = normalize fragment;
      in {
        packages = acc.packages ++ spec.packages;
        env = acc.env // spec.env;
        shellHook = acc.shellHook + spec.shellHook;
      }
    ) {
      packages = [];
      env = {};
      shellHook = "";
    }
    fragments;

  mkShell = {
    pkgs,
    fragments ? [],
    packages ? [],
    env ? {},
    extraShellHook ? "",
    builder ? null,
    mkShellArgs ? {},
  }: let
    spec = merge (
      fragments
      ++ [
        {
          inherit packages env;
          shellHook = extraShellHook;
        }
      ]
    );
    drv =
      if builder != null
      then
        builder spec
      else
        pkgs.mkShell (
          mkShellArgs
          // {
            inherit (spec) packages env shellHook;
          }
        );
  in
    drv
    // {
      passthru = (drv.passthru or {}) // {devShellSpec = spec;};
    };
}
