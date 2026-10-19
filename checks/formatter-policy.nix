{
  pkgs,
  treefmt-nix,
  lib,
}: let
  policy = lib.opencode.formatterPolicy;
  tree = treefmt-nix.lib.evalModule pkgs {programs.just.enable = true;};
  config.treefmt = tree.config;
  fixtures = policy.fixtures {inherit pkgs treefmt-nix config;};
  resolver = policy.mkResolver {inherit pkgs;} config;
  formatters =
    tree.config.settings.formatter
    // {
      direct = {
        command = pkgs.lib.getExe pkgs.alejandra;
        options = ["--check" "."];
      };
    };
  bashMap = lib.opencode.formatPolicy.bashDenies {};
  evaluate = map:
    policy.coverage {
      inherit formatters;
      inherit (resolver) resolveDirect;
      bashMap = map;
    };
  valid = evaluate bashMap;
  missing = evaluate {};
  permissive = evaluate (bashMap // {"alejandra *" = "allow";});
  blanket = evaluate (bashMap // {"*" = "deny";});
in
  assert fixtures.ok;
  assert pkgs.lib.assertMsg (valid.report.uncovered == [] && valid.report.unattributable == [])
  "formatter-policy: ${builtins.toJSON valid.report}";
  assert valid.report.envTwinNecessary && valid.report.pathTwinNecessary;
  assert missing.report.uncovered != [] && missing.report.unattributable == [];
  assert permissive.report.nonDeny == ["alejandra *"];
  assert blanket.report.unattributable != [];
  assert !blanket.report.envTwinNecessary && !blanket.report.pathTwinNecessary;
    pkgs.runCommand "formatter-policy" {
      fixtureReport = builtins.toJSON fixtures.report;
      coverageReport = builtins.toJSON valid.report;
    } ''
      mkdir -p "$out"
      printf '%s\n' "$fixtureReport" > "$out/fixtures.json"
      printf '%s\n' "$coverageReport" > "$out/coverage.json"
    ''
