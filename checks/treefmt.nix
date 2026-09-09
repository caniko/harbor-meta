{
  pkgs,
  treefmt-nix,
  modules,
}: let
  nixOnly = (treefmt-nix.lib.evalModule pkgs {imports = [modules.nix];}).config;
  tomlOnly = (treefmt-nix.lib.evalModule pkgs {imports = [modules.toml];}).config;
  composed =
    (treefmt-nix.lib.evalModule pkgs {
      imports = [modules.nix modules.toml modules.nix];
      projectRootFile = "flake.nix";
      settings.excludes = ["generated/**"];
    }).config;
  reversed =
    (treefmt-nix.lib.evalModule pkgs {
      imports = [modules.toml modules.nix];
      projectRootFile = "flake.nix";
      settings.excludes = ["generated/**"];
    }).config;
in
  assert builtins.attrNames nixOnly.settings.formatter == ["alejandra"];
  assert builtins.attrNames tomlOnly.settings.formatter == ["taplo"];
  assert composed.settings == reversed.settings;
    pkgs.runCommand "harbor-meta-treefmt-modules" {
      nativeBuildInputs = [composed.build.wrapper];
    } ''
        export HOME="$TMPDIR/home"
        mkdir -p "$HOME" generated
        cp ${pkgs.writeText "unformatted.nix" "{ x=1; }\n"} flake.nix
        cp ${pkgs.writeText "unformatted.toml" "x=1\n"} sample.toml
        cp flake.nix generated/skip.nix
        chmod -R u+w .
        treefmt --tree-root . flake.nix sample.toml generated/skip.nix
        ! cmp -s flake.nix generated/skip.nix
        cmp ${pkgs.writeText "unformatted.nix" "{ x=1; }\n"} generated/skip.nix
      treefmt --tree-root . --clear-cache --fail-on-change flake.nix sample.toml generated/skip.nix
        touch "$out"
    ''
