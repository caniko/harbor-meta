{
  lib,
  formatPolicy,
}: let
  mkJustScript = justExe: indentArgs: ''
    for f in "$@"; do
      ${justExe} --fmt --unstable ${lib.escapeShellArgs indentArgs} --justfile "$f"
    done
  '';
  mkResolver = {pkgs}: config: let
    justProgramCfg =
      if config ? treefmt && config.treefmt ? programs && config.treefmt.programs ? just
      then config.treefmt.programs.just
      else throw "opencode-root-policy-coverage: missing config.treefmt.programs.just; refusing to guess just contract";
    justPackage = justProgramCfg.package or pkgs.just;
    justIndentation = justProgramCfg.indentation or null;
    justIndentationArgs = lib.optionals (justIndentation != null) ["--indentation" justIndentation];
    expectedJustExe = lib.getExe justPackage;
    expectedJustScript = mkJustScript expectedJustExe justIndentationArgs;
    expectedBashExe = lib.getExe pkgs.bash;
    justContract = {
      inherit justPackage justIndentation justIndentationArgs expectedJustExe expectedJustScript;
    };
    lineTerminators = ["\n" "\r" (builtins.fromJSON ''"\u2028"'') (builtins.fromJSON ''"\u2029"'')];
    hasLineTerm = text: lib.any (term: lib.hasInfix term text) lineTerminators;
    normalizeEntry = name: entry: let
      rawCommand = entry.command or (throw "opencode-root-policy-coverage: formatter ${name} has no command");
      argTokens = map builtins.toString ((entry.options or []) ++ (entry.args or []));
      tokens =
        if builtins.isString rawCommand
        then lib.splitString " " rawCommand
        else if builtins.isList rawCommand && lib.all builtins.isString rawCommand
        then rawCommand
        else throw "opencode-root-policy-coverage: formatter ${name} command has an unsupported shape";
    in
      if tokens == [] || builtins.head tokens == ""
      then throw "opencode-root-policy-coverage: formatter ${name} command has an unsupported shape"
      else {
        exe = builtins.head tokens;
        args = lib.tail tokens ++ argTokens;
      };
    resolveDirect = name: entry: let
      norm = normalizeEntry name entry;
      base = builtins.baseNameOf norm.exe;
      rest = lib.concatStringsSep " " norm.args;
    in
      if name == "just"
      then
        if justIndentation != null
        then throw "opencode-root-policy-coverage: formatter just wrapper uses nondefault --indentation; refusing to silently discard flags"
        else if norm.exe != expectedBashExe
        then throw "opencode-root-policy-coverage: formatter just wrapper has unexpected bash executable ${norm.exe}; expected ${expectedBashExe}; refusing to guess its agent invocation"
        else if norm.args != ["-euc" expectedJustScript "--"]
        then
          if builtins.length norm.args == 3 && lib.hasInfix "--indentation" (builtins.toString (builtins.elemAt norm.args 1))
          then throw "opencode-root-policy-coverage: formatter just wrapper uses nondefault --indentation; refusing to silently discard flags"
          else throw "opencode-root-policy-coverage: formatter just wrapper body does not match the pinned treefmt-nix wrapper; refusing to guess its agent invocation"
        else {
          head = expectedJustExe;
          rest = "--fmt --unstable";
        }
      else if builtins.elem base ["bash" "sh" "dash"] || norm.exe == expectedBashExe
      then throw "opencode-root-policy-coverage: formatter ${name} is a shell wrapper with no adapter; refusing to guess its agent invocation"
      else if hasLineTerm norm.exe || hasLineTerm rest
      then throw "opencode-root-policy-coverage: formatter ${name} has multiline options/args with no adapter; refusing to guess its agent invocation"
      else {
        head = norm.exe;
        inherit rest;
      };
  in {
    inherit justProgramCfg justContract expectedBashExe resolveDirect;
  };
  coverage = {
    formatters,
    resolveDirect,
    bashMap,
  }: let
    programs = builtins.attrNames formatters;
    denyKeys = builtins.attrNames bashMap;
    nonDenyKeys = lib.filter (key: bashMap.${key} != "deny") denyKeys;
    matchesAny = keys: command: lib.any (key: formatPolicy.matcher.match key command) keys;
    # Only single-line agent invocations reach the matcher. Nix regex dots
    # cross newlines; OpenCode's JS matcher does not. Never match wrapper blobs.
    programInvocations = name: let
      direct = resolveDirect name formatters.${name};
      inherit (direct) head rest;
      base =
        if lib.hasPrefix "/" head || lib.hasPrefix "./" head
        then builtins.baseNameOf head
        else builtins.head (lib.splitString " " head);
      suffix = lib.optionalString (rest != "") " ${rest}";
      bareLine = "${base}${suffix}";
      exactLine = "${head}${suffix}";
      storeAliasLine = "/nix/store/00000000000000000000000000000000-alias/bin/${base}${suffix}";
      resultLine = "./result/bin/${base}${suffix}";
    in
      lib.unique (lib.concatMap (line: [line "AGENT_TEST_ENV=1 ${line}"]) [bareLine exactLine storeAliasLine resultLine]);
    commandsOf = name: map (command: {inherit name command;}) (programInvocations name);
    allCommands = lib.concatMap commandsOf programs;
    uncoveredCommands = lib.filter (c: !(matchesAny denyKeys c.command)) allCommands;
    coveredOf = name: lib.filter (command: matchesAny denyKeys command) (programInvocations name);
    killersOf = name: let
      covered = coveredOf name;
    in
      if covered == []
      then []
      else
        lib.filter (base:
          !(lib.all (command: matchesAny (lib.subtractLists (lib.unique (formatPolicy.expandPattern true base)) denyKeys) command) covered))
        formatPolicy.patterns;
    unattributable = lib.filter (name: coveredOf name != [] && killersOf name == []) programs;
    isEnvKey = key: lib.hasPrefix "*=* " key;
    isPathKey = key: lib.any (prefix: lib.hasPrefix prefix key) ["/nix/store/" "*=* /nix/store/" "./result/bin/" "*=* ./result/bin/"];
    noEnvKeys = lib.filter (key: !(isEnvKey key)) denyKeys;
    noPathKeys = lib.filter (key: !(isPathKey key)) denyKeys;
    envCommands = lib.filter (c: lib.hasPrefix "AGENT_TEST_ENV=1 " c.command) allCommands;
    pathCommands = lib.filter (c: lib.any (prefix: lib.hasPrefix prefix c.command) ["/nix/store/" "AGENT_TEST_ENV=1 /nix/store/" "./result/bin/" "AGENT_TEST_ENV=1 ./result/bin/"]) allCommands;
    envUncoveredWithoutTwins = lib.filter (c: !(matchesAny noEnvKeys c.command)) envCommands;
    pathUncoveredWithoutTwins = lib.filter (c: !(matchesAny noPathKeys c.command)) pathCommands;
    describe = commands: map (c: "${c.name}: ${c.command}") commands;
  in {
    inherit programInvocations uncoveredCommands unattributable nonDenyKeys envUncoveredWithoutTwins pathUncoveredWithoutTwins;
    report = {
      formatters = programs;
      commands = lib.genAttrs programs programInvocations;
      killers = lib.genAttrs programs killersOf;
      uncovered = describe uncoveredCommands;
      inherit unattributable;
      nonDeny = nonDenyKeys;
      envTwinNecessary = envUncoveredWithoutTwins != [];
      pathTwinNecessary = pathUncoveredWithoutTwins != [];
      envUncoveredWithoutTwins = describe envUncoveredWithoutTwins;
      pathUncoveredWithoutTwins = describe pathUncoveredWithoutTwins;
      mirrorNotes = "all representatives are single-line by construction; wrapper blobs are never matched";
    };
  };
in {
  inherit mkJustScript mkResolver coverage;
  fixtures = import ./formatter-policy-fixtures.nix {inherit lib mkJustScript mkResolver coverage;};
}
