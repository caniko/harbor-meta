# Regression suite for lib.treefmtScope (fleet composition contract).
#
# Eval-time asserts cover scoping, preservation, central overrides, identity
# reporting and every rejection case. The runCommand below proves runtime
# behavior on fixture copies: per-scope options, exclusions, prettier config
# discovery from a foreign cwd, and idempotence.
{
  pkgs,
  system,
  nixpkgs,
  lib,
  treefmt-nix,
  rust-overlay,
}: let
  scope = lib.treefmtScope;
  nlib = nixpkgs.lib;
  overlayPkgs = import nixpkgs {
    inherit system;
    overlays = [(import rust-overlay)];
  };
  # Fleet pin under test: simit-shaped modules inject nightly-only
  # skip_children, so the suite must run on nightly rustfmt.
  centralRustfmt =
    overlayPkgs.rust-bin.nightly."2026-09-15".default.override
    {extensions = ["rustfmt"];};
  centralRustfmtExe = "${centralRustfmt}/bin/rustfmt";

  fixtureA = {
    programs.alejandra = {
      enable = true;
      priority = 10;
    };
    programs.rustfmt = {
      enable = true;
      edition = "2021";
    };
    settings.formatter.rustfmt.options = ["--config" "max_width=40"];
    programs.taplo.enable = true;
  };

  # Deliberately different edition, options, defaults policy and prettier
  # coverage, plus a project-pinned taplo wrapper to exercise override
  # detection (still functional: it execs the same taplo).
  fixtureB = {
    enableDefaultExcludes = false;
    programs.alejandra.enable = true;
    programs.rustfmt = {
      enable = true;
      edition = "2024";
    };
    programs.taplo = {
      enable = true;
      package = pkgs.writeShellScriptBin "taplo" ''exec ${pkgs.taplo}/bin/taplo "$@"'';
    };
    programs.prettier = {
      enable = true;
      excludes = ["/generated/**"];
      includes = ["*.md"];
    };
  };

  projects = [
    {
      name = "proj-a";
      relPath = "fleet/proj-a";
      modules = [fixtureA];
    }
    {
      name = "proj-b";
      relPath = "fleet/proj-b";
      modules = [fixtureB];
    }
  ];

  composed = scope.compose {
    inherit treefmt-nix pkgs projects;
    centralPackages = {rustfmt = centralRustfmt;};
  };

  formatters = composed.evalResult.config.settings.formatter;
  byName = name: formatters.${name};
  sourceOf = scopedName: let
    project = nlib.findFirst (project:
        (nlib.findFirst (formatter: formatter.name == scopedName) null
          project.formatters) != null)
      null
      composed.report.projects;
    match =
      if project == null
      then null
      else nlib.findFirst (formatter: formatter.name == scopedName) null project.formatters;
  in
    if match == null
    then null
    else match.source;

in
  # --- scoping ---
  assert (byName "fleet-proj-a-alejandra").includes == ["fleet/proj-a/**/*.nix"];
  assert (byName "fleet-proj-a-alejandra").options == [];
  # --- preservation: priority and custom options survive composition ---
  assert (byName "fleet-proj-a-alejandra").priority == 10;
  assert builtins.sort builtins.lessThan (byName "fleet-proj-a-rustfmt").options
    == builtins.sort builtins.lessThan ["--config" "skip_children=true" "--edition" "2021" "--config" "max_width=40"];
  assert (byName "fleet-proj-b-rustfmt").options == ["--config" "skip_children=true" "--edition" "2024"];
  # --- central override: same pinned binary, distinct per-project editions ---
  assert (byName "fleet-proj-a-rustfmt").command == centralRustfmtExe;
  assert (byName "fleet-proj-b-rustfmt").command == centralRustfmtExe;
  assert sourceOf "fleet-proj-a-rustfmt" == "central";
  assert sourceOf "fleet-proj-b-rustfmt" == "central";
  # --- shared pkgs identity and project override detection ---
  assert sourceOf "fleet-proj-a-alejandra" == "shared-pkgs";
  assert sourceOf "fleet-proj-b-taplo" == "project-override";
  # --- prettier scoping: bare globs gain **, rooted excludes stay rooted ---
  assert (byName "fleet-proj-b-prettier").includes == ["fleet/proj-b/**/*.md"];
  assert (byName "fleet-proj-b-prettier").excludes == ["fleet/proj-b/generated/**"];
  # --- disabled defaults survive: *.lock must not be excluded for proj-b ---
  assert !(nlib.elem "fleet/proj-b/*.lock"
    composed.evalResult.config.settings.excludes);
  # --- root marker forced once ---
  assert composed.evalResult.config.projectRootFile == "flake.nix";
  # --- rejections (must all fail) ---
  assert !(builtins.tryEval (builtins.toJSON (scope.compose {
    inherit treefmt-nix pkgs;
    centralPackages = {rustfmt = centralRustfmt;};
    projects = [
      {
        name = "overlap-parent";
        relPath = "fleet/proj-a";
        modules = [fixtureA];
      }
      {
        name = "overlap-child";
        relPath = "fleet/proj-a/nested";
        modules = [fixtureB];
      }
    ];
  }).report)).success;
  assert !(builtins.tryEval (builtins.toJSON (scope.compose {
    inherit treefmt-nix pkgs;
    centralPackages = {rustfmt = centralRustfmt;};
    projects = [
      {
        name = "slug-one";
        relPath = "fleet/a-b";
        modules = [fixtureA];
      }
      {
        name = "slug-two";
        relPath = "fleet/a/b";
        modules = [fixtureA];
      }
    ];
  }).report)).success;
  assert !(builtins.tryEval (builtins.toJSON (scope.compose {
    inherit treefmt-nix pkgs;
    centralPackages = {rustfmt = centralRustfmt;};
    projects = [
      {
        name = "dotdot";
        relPath = "fleet/../escape";
        modules = [fixtureA];
      }
    ];
  }).report)).success;
  assert !(builtins.tryEval (builtins.toJSON (scope.compose {
    inherit treefmt-nix pkgs;
    centralPackages = {rustfmt = centralRustfmt;};
    projects = [
      {
        name = "empty";
        relPath = "fleet/empty";
        modules = [];
      }
    ];
  }).report)).success;
  pkgs.runCommand "harbor-meta-treefmt-scope" {
    nativeBuildInputs = [composed.evalResult.config.build.wrapper];
  } ''
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME" fleet/proj-a fleet/proj-b/generated
    cp ${pkgs.writeText "unformatted.nix" "{ x=1; }\n"} fleet/proj-a/flake.nix
    cp ${pkgs.writeText "unformatted.rs" "fn main() { let some_extremely_long_variable_name = 1; println!(\"{}\", some_extremely_long_variable_name); }\n"} fleet/proj-a/main.rs
    cp ${pkgs.writeText "unformatted.toml" "x=1\n"} fleet/proj-b/sample.toml
    cp ${pkgs.writeText "unformatted.rs" "fn main() { let some_extremely_long_variable_name = 1; println!(\"{}\", some_extremely_long_variable_name); }\n"} fleet/proj-b/main.rs
    cp ${pkgs.writeText "unformatted.md" "# hi\n\nsome   text\n"} fleet/proj-b/doc.md
    cp ${pkgs.writeText "prettierrc" "{\"printWidth\": 80, \"proseWrap\": \"always\"}\n"} fleet/proj-b/.prettierrc
    cp ${pkgs.writeText "excluded.md" "# untouched\n"} fleet/proj-b/generated/skip.md
    cp ${pkgs.writeText "root.nix" "{ y=2; }\n"} root-skip.nix
    chmod -R u+w .
    # Run from the parent: per-file config discovery (prettier) must still work.
    treefmt --walk filesystem fleet/proj-a fleet/proj-b
    ! cmp -s ${pkgs.writeText "unformatted.nix" "{ x=1; }\n"} fleet/proj-a/flake.nix
    ! cmp -s ${pkgs.writeText "unformatted.toml" "x=1\n"} fleet/proj-b/sample.toml
    ! cmp -s ${pkgs.writeText "unformatted.md" "# hi\n\nsome   text\n"} fleet/proj-b/doc.md
    cmp ${pkgs.writeText "excluded.md" "# untouched\n"} fleet/proj-b/generated/skip.md
    cmp ${pkgs.writeText "root.nix" "{ y=2; }\n"} root-skip.nix
    treefmt --walk filesystem --clear-cache --fail-on-change fleet/proj-a fleet/proj-b
    touch "$out"
  ''
