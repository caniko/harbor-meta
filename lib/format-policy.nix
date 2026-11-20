{lib}: let
  # Identity marker written into every Harbor-rendered OpenCode config.
  # `harbor-opencode sync` uses it to tell its own output from a hand-written
  # config and refuses to clobber the latter without --force. Upstream
  # OpenCode's config normalizer ignores unknown keys such as this marker.
  marker = "harbor.meta/opencode-config";
  markerValue = "1";

  # Every formatter invocation the agent policy denies. Each entry owns one
  # owner/tool row from docs/treefmt.md (or the fleet/root policy tools that
  # treefmt orchestrates) and lists its deny patterns:
  #
  #   - whole-tool formatters get `<tool> *` (the trailing ` *` also matches
  #     the bare command, so `<tool>` alone is denied too);
  #   - multi-purpose tools only get their formatting subcommand so build,
  #     lint, and plan invocations stay governed by the global policy.
  #
  # Patterns are language-independent: they cover the whole fleet regardless
  # of which profile subset (or none at all) a project's config renders.
  registry = [
    {
      patterns = ["alejandra *"];
      source = "harbor-meta treefmtModules.nix (Alejandra)";
    }
    {
      patterns = ["taplo *"];
      source = "harbor-meta treefmtModules.toml (Taplo)";
    }
    {
      patterns = [
        "rustfmt *"
        "cargo fmt *"
      ];
      source = "harbor-rs treefmtModules.rust (rustfmt)";
    }
    {
      patterns = [
        "prettier *"
        "npx prettier *"
        "pnpm exec prettier *"
        "pnpm dlx prettier *"
        "yarn dlx prettier *"
        "bunx prettier *"
      ];
      source = "harbor-js treefmtModules.javascript (Prettier, incl. exec twins)";
    }
    {
      patterns = [
        "ruff format *"
        "ruff check *--fix*"
      ];
      source = "harbor-py treefmtModules.python (Ruff format; `ruff check` without --fix stays allowed)";
    }
    {
      patterns = ["google-java-format *"];
      source = "harbor-android treefmtModules.java (google-java-format)";
    }
    {
      patterns = ["ktfmt *"];
      source = "harbor-android treefmtModules.kotlin (ktfmt)";
    }
    {
      patterns = ["forge fmt *"];
      source = "harbor-eth treefmtModules.solidity (Forge fmt)";
    }
    {
      patterns = ["latexindent *"];
      source = "harbor-tex treefmtModules.latex (latexindent)";
    }
    {
      patterns = [
        "deadnix *"
        "gofmt *"
        "just --fmt *"
        "statix *"
        "statix-fix *"
        "terraform fmt *"
      ];
      source = "fleet treefmt programs (canix-toolbelt flake-modules/formatters.nix; statix runs as the statix-fix wrapper binary)";
    }
    {
      patterns = [
        "shfmt *"
        "shfmt -d *"
      ];
      source = "root policy (agent_safety allows shfmt -d; treefmt --fail-on-change is the sanctioned path)";
    }
    {
      patterns = [
        "tofu fmt *"
        "go fmt *"
        "nix fmt *"
      ];
      source = "root policy (OpenTofu/Go formatting, nix fmt realises arbitrary outputs)";
    }
  ];

  patterns = lib.unique (lib.concatMap (entry: entry.patterns) registry);

  # Upstream OpenCode's Wildcard.match applies `*` to the whole command,
  # not just to an assignment or path component. `*=* foo *` and
  # `/nix/store/*/bin/foo *` can therefore deny unrelated commands whose
  # arguments mention foo. Emit only the bare pattern and its literal
  # `./result/bin/` variant; unmatched commands fall through to ask.
  expandPattern = storePathTwins: pattern: let
    cmd = builtins.head (lib.splitString " " pattern);
    binaryShaped = !(lib.hasInfix "*" cmd) && !(lib.hasInfix "?" cmd) && !(lib.hasInfix "=" cmd);
  in
    [pattern] ++ lib.optional (storePathTwins && binaryShaped) "./result/bin/${pattern}";

  # The `permission.bash` map merged into every rendered config. Every value
  # is "deny"; there is deliberately no `"*": "deny"` (or ask) catch-all —
  # opencode defaults unmatched commands to "ask" (fail-closed), and a
  # catch-all would also swallow the global allow rules for treefmt/git/read
  # tools that projects are expected to inherit.
  bashDenies = {
    storePathTwins ? true,
    extra ? [],
  }:
    lib.listToAttrs (
      map (pattern: {
        name = pattern;
        value = "deny";
      }) (lib.unique (lib.concatMap (expandPattern storePathTwins) (patterns ++ extra)))
    );

  # Replay upstream OpenCode 2.3.2's Wildcard.match
  # (packages/core/src/util/wildcard.ts) for Linux commands using `/` paths.
  # Escape metacharacters, translate `*` to `.*` and `?` to `.`, and make a
  # trailing ` .*` optional. builtins.match anchors the full string like
  # OpenCode's `new RegExp("^" + escaped + "$", "s")`.
  matcher = rec {
    globToEre = glob: let
      normalized = lib.replaceStrings ["\\"] ["/"] glob;
      escaped =
        lib.replaceStrings
        ["." "+" "^" "$" "{" "}" "(" ")" "|" "[" "]"]
        ["\\." "\\+" "\\^" "\\$" "\\{" "\\}" "\\(" "\\)" "\\|" "\\[" "\\]"]
        normalized;
      starred = lib.replaceStrings ["*"] [".*"] escaped;
      questioned = lib.replaceStrings ["?"] ["."] starred;
    in
      if lib.hasSuffix " .*" questioned
      then lib.removeSuffix " .*" questioned + "( .*)?"
      else questioned;

    match = pattern: input: builtins.match (globToEre pattern) input != null;
  };
in {
  inherit
    marker
    markerValue
    registry
    patterns
    expandPattern
    bashDenies
    matcher
    ;
}
