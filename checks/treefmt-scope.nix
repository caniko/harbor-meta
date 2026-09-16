# Regression suite for lib.treefmtScope (fleet composition contract).
#
# Eval-time asserts cover scoping, preservation, central overrides, identity
# reporting and every rejection case. The runCommand proofs below execute the
# real wrappers on fixture copies: per-scope options, exclusions, prettier
# config discovery from a foreign cwd, local-vs-global byte equivalence, and
# idempotence.
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

  # Root policy fixture: covers the workspace root while child subtrees are
  # composed alongside it.
  fixtureRoot = {
    programs.alejandra.enable = true;
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

  allowedTaplo = ["fleet/proj-b:taplo"];

  composed = scope.compose {
    inherit treefmt-nix pkgs projects;
    centralPackages = {rustfmt = centralRustfmt;};
    allowedOverrides = allowedTaplo;
  };

  composedRoot = scope.compose {
    inherit treefmt-nix pkgs;
    centralPackages = {rustfmt = centralRustfmt;};
    allowedOverrides = allowedTaplo;
    projects = [
      {
        name = "root";
        relPath = "";
        isRoot = true;
        modules = [fixtureRoot];
      }
    ]
    ++ projects;
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

  mustFail = expr: !(builtins.tryEval (builtins.toJSON expr)).success;

  failReport = args: mustFail (scope.compose args).report;

  # Standalone local wrappers built from the same fixtures and toolchain.
  # The runtime proof formats identical copies locally and globally, then
  # requires byte-identical trees.
  localWrapper = fixture: edition:
    (treefmt-nix.lib.evalModule overlayPkgs {
      imports = [
        fixture
        {
          programs.rustfmt.package = nlib.mkForce centralRustfmt;
          programs.rustfmt.edition = nlib.mkForce edition;
        }
      ];
      projectRootFile = "flake.nix";
    }).config.build.wrapper;
  localA = localWrapper fixtureA "2021";
  localB = localWrapper fixtureB "2024";

  unformattedNix = pkgs.writeText "unformatted.nix" "{ x=1; }\n";
  unformattedRs = pkgs.writeText "unformatted.rs" "fn main() { let some_extremely_long_variable_name = 1; println!(\"{}\", some_extremely_long_variable_name); }\n";
  unformattedToml = pkgs.writeText "unformatted.toml" "x=1\n";
  unformattedMd = pkgs.writeText "unformatted.md" "# hi\n\nsome   text\n";
  prettierRc = pkgs.writeText "prettierrc" "{\"printWidth\": 80, \"proseWrap\": \"always\"}\n";
  excludedMd = pkgs.writeText "excluded.md" "# untouched\n";
  rootNix = pkgs.writeText "root.nix" "{ y=2; }\n";
  spacedMd = pkgs.writeText "spaced.md" "# spaced out\n\nmore    spaces\n";
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
  # --- root entry: every child subtree excluded from root formatters ---
  assert (composedRoot.evalResult.config.settings.formatter.root-alejandra).excludes
    == ["fleet/proj-a/**" "fleet/proj-b/**"];
  assert (composedRoot.evalResult.config.settings.formatter.root-alejandra).includes
    == ["*.nix"];
  # --- unresolved divergence fails wrapper preparation ---
  assert failReport {
    inherit treefmt-nix pkgs projects;
    centralPackages = {rustfmt = centralRustfmt;};
  };
  # --- rejections (must all fail) ---
  assert failReport {
    inherit treefmt-nix pkgs;
    centralPackages = {rustfmt = centralRustfmt;};
    allowedOverrides = allowedTaplo;
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
  };
  assert failReport {
    inherit treefmt-nix pkgs;
    centralPackages = {rustfmt = centralRustfmt;};
    allowedOverrides = allowedTaplo;
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
  };
  assert failReport {
    inherit treefmt-nix pkgs;
    centralPackages = {rustfmt = centralRustfmt;};
    allowedOverrides = allowedTaplo;
    projects = [
      {
        name = "final-collision";
        relPath = "fleet/a";
        modules = [{settings.formatter."b-c" = {
          command = "${pkgs.hello}/bin/hello";
          includes = ["*.txt"];
        };}];
      }
      {
        name = "final-collision-other";
        relPath = "fleet/a-b";
        modules = [{settings.formatter."c" = {
          command = "${pkgs.hello}/bin/hello";
          includes = ["*.txt"];
        };}];
      }
    ];
  };
  assert failReport {
    inherit treefmt-nix pkgs;
    centralPackages = {rustfmt = centralRustfmt;};
    allowedOverrides = allowedTaplo;
    projects = [
      {
        name = "dotdot";
        relPath = "fleet/../escape";
        modules = [fixtureA];
      }
    ];
  };
  assert failReport {
    inherit treefmt-nix pkgs;
    centralPackages = {rustfmt = centralRustfmt;};
    allowedOverrides = allowedTaplo;
    projects = [
      {
        name = "empty";
        relPath = "fleet/empty";
        modules = [];
      }
    ];
  };
  assert failReport {
    inherit treefmt-nix pkgs;
    centralPackages = {rustfmt = centralRustfmt;};
    allowedOverrides = allowedTaplo;
    projects = [
      {
        name = "relref";
        relPath = "fleet/relref";
        modules = [{settings.formatter.taplo = {
          command = "${pkgs.taplo}/bin/taplo";
          includes = ["*.toml"];
          options = ["--config" "./taplo.toml"];
        };}];
      }
    ];
  };
  pkgs.runCommand "harbor-meta-treefmt-scope" {
    nativeBuildInputs = [
      composed.evalResult.config.build.wrapper
      localA
      localB
    ];
  } ''
    export HOME="$TMPDIR/home"
    seed_tree() {
      root="$1"
      mkdir -p "$root/fleet/proj-a" "$root/fleet/proj-b/generated"
      cp ${unformattedNix} "$root/fleet/proj-a/flake.nix"
      cp ${unformattedRs} "$root/fleet/proj-a/main.rs"
      cp ${unformattedToml} "$root/fleet/proj-b/sample.toml"
      cp ${unformattedRs} "$root/fleet/proj-b/main.rs"
      cp ${unformattedMd} "$root/fleet/proj-b/doc.md"
      cp ${unformattedMd} "$root/fleet/proj-b/my doc.md"
      cp ${prettierRc} "$root/fleet/proj-b/.prettierrc"
      cp ${excludedMd} "$root/fleet/proj-b/generated/skip.md"
      cp ${rootNix} "$root/root-skip.nix"
      chmod -R u+w "$root"
    }
    seed_tree case-local
    seed_tree case-global
    # Local wrappers run inside their own project roots...
    (cd case-local/fleet/proj-a && "${localA}/bin/treefmt" --walk filesystem .)
    (cd case-local/fleet/proj-b && "${localB}/bin/treefmt" --walk filesystem .)
    # ...while the global wrapper runs once from the parent over both subtrees.
    (cd case-global && treefmt --walk filesystem fleet/proj-a fleet/proj-b)
    # Byte equivalence between local and global formatting.
    diff -r case-local/fleet/proj-a case-global/fleet/proj-a
    diff -r case-local/fleet/proj-b case-global/fleet/proj-b
    # Expected changes happened...
    ! cmp -s ${unformattedNix} case-global/fleet/proj-a/flake.nix
    ! cmp -s ${unformattedToml} case-global/fleet/proj-b/sample.toml
    ! cmp -s ${unformattedMd} case-global/fleet/proj-b/doc.md
    ! cmp -s ${unformattedMd} "case-global/fleet/proj-b/my doc.md"
    # ...exclusions and non-selected files stayed byte-identical...
    cmp ${excludedMd} case-global/fleet/proj-b/generated/skip.md
    cmp ${rootNix} case-global/root-skip.nix
    # ...and a fresh-cache second pass is clean.
    (cd case-global && treefmt --walk filesystem --clear-cache --fail-on-change fleet/proj-a fleet/proj-b)
    touch "$out"
  ''
