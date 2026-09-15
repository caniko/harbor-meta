# Fleet treefmt composition contract.
#
# Builds ONE treefmt configuration from per-project treefmt modules so a
# single version-aligned wrapper formats every selected project subtree.
# Project modules supply policy (which formatters, which options, which
# globs); this contract supplies scoping (validated workspace-relative paths,
# unique formatter names) while one shared `pkgs` — plus explicit
# `centralPackages` — supplies one binary per tool for the whole fleet.
#
# Intended caller is fleet orchestration (canix `fleet/format-driver.nix`);
# this file stays pure: project discovery and absolute module paths are
# caller inputs, never baked in here.
{lib}: let
  globChars = ["*" "?" "[" "]" "{" "}" "\\"];

  hasGlobChars = segment:
    lib.any (char: lib.hasInfix char segment) globChars;

  # Validate a workspace-relative project root and return it normalized
  # (leading `./` stripped). Throws on absolute paths, `.`, `..` segments,
  # empty segments, and glob characters — all before anything is formatted.
  validateRelPath = name: relPath: let
    stripped =
      if lib.hasPrefix "./" relPath
      then lib.removePrefix "./" relPath
      else relPath;
    segments = lib.splitString "/" stripped;
  in
    assert lib.assertMsg (builtins.isString relPath && relPath != "")
      "treefmt-scope: project ${name} has an empty relPath";
    assert lib.assertMsg (!lib.hasPrefix "/" relPath)
      "treefmt-scope: project ${name} relPath must be workspace-relative, got ${relPath}";
    assert lib.assertMsg (lib.all (segment:
      segment != "" && segment != "." && segment != ".." && !hasGlobChars segment)
      segments)
      "treefmt-scope: project ${name} relPath is not a clean relative path, got ${relPath}";
      stripped;

  slugOf = relPath: lib.replaceStrings ["/"] ["-"] relPath;

  # True when `other` equals `root` or lives beneath it.
  nestsUnder = root: other:
    other == root || lib.hasPrefix (root + "/") other;

  # Prefix a project-local glob with its workspace-relative path.
  # Bare names (`*.md`) match basenames at any depth, so they need `**/`;
  # already-rooted or nested patterns keep their shape under the prefix.
  scopePattern = relPath: pattern:
    if pattern == "*"
    then "${relPath}/**"
    else if lib.hasInfix "/" pattern
    then
      if lib.hasPrefix "/" pattern
      then "${relPath}${pattern}"
      else "${relPath}/${pattern}"
    else "${relPath}/**/${pattern}";

  # Scope one evaluated formatter entry beneath relPath, preserving every
  # other key verbatim (options, priority, custom settings).
  scopeFormatter = relPath: formatter:
    formatter
    // {
      includes =
        if formatter ? includes
        then map (scopePattern relPath) formatter.includes
        else ["${relPath}/**"];
      excludes = map (scopePattern relPath) (formatter.excludes or []);
    };

  evalProject = treefmt-nix: pkgs: project: extraModules:
    (treefmt-nix.lib.evalModule pkgs {
      imports = project.modules ++ extraModules;
      projectRootFile = "flake.nix";
      _module.args = project.extraArgs or {};
    }).config;

  enabledPrograms = config:
    lib.filterAttrs (_: program: (program.enable or false))
    (config.programs or {});

  # Central packages win via mkForce, but only for programs the project
  # actually enables — otherwise we would silently ADD formatters.
  # Returns { names, modules }: names get the override so identity reporting
  # can attribute the effective binary without reimplementing each program's
  # mainProgram resolution.
  overridesFor = centralPackages: enabled: let
    names = lib.intersectLists (builtins.attrNames centralPackages)
      (builtins.attrNames enabled);
  in {
    inherit names;
    modules = lib.optional (names != []) {
      programs = lib.genAttrs names
        (name: {package = lib.mkForce centralPackages.${name};});
    };
  };

  # Baseline command for one program from shared pkgs alone (no project
  # modules). Null when a bare enable does not evaluate — reported honestly
  # instead of guessed.
  baselineCommand = treefmt-nix: pkgs: name: let
    attempt = builtins.tryEval ((treefmt-nix.lib.evalModule pkgs {
      imports = [{programs.${name}.enable = true;}];
      projectRootFile = "flake.nix";
    }).config.settings.formatter.${name}.command or null);
  in
    if attempt.success
    then attempt.value
    else null;

  compose = {
    treefmt-nix,
    pkgs,
    centralPackages ? {},
    projects,
  }: let
    normalized =
      map (project: project // {relPath = validateRelPath project.name project.relPath;})
      projects;

    slugs = map (project: slugOf project.relPath) normalized;
    _slugCheck = assert lib.assertMsg
      (builtins.length (lib.unique slugs) == builtins.length slugs)
      "treefmt-scope: relPath slug collision (e.g. a/b vs a-b)";
      true;

    _overlapCheck = assert lib.assertMsg (lib.all (project:
        !(lib.any (other:
          other.relPath != project.relPath
          && nestsUnder other.relPath project.relPath)
        normalized))
      normalized)
      "treefmt-scope: overlapping project roots (duplicate or nested relPath)";
      true;

    scopedOne = project: let
      first = evalProject treefmt-nix pkgs project [];
      enabled = enabledPrograms first;
      overrides = overridesFor centralPackages enabled;
      settings =
        if overrides.modules == []
        then first.settings
        else (evalProject treefmt-nix pkgs project overrides.modules).settings;
      formatters = settings.formatter or {};
      _nonempty = assert lib.assertMsg (formatters != {})
        "treefmt-scope: project ${project.name} produced no formatters";
        true;
      slug = slugOf project.relPath;
      scoped = lib.mapAttrs'
        (name: formatter: lib.nameValuePair "${slug}-${name}" (scopeFormatter project.relPath formatter))
        formatters;
    in
      builtins.seq _nonempty {
        inherit (project) name;
        inherit (project) relPath;
        centralNames = overrides.names;
        formatterNames = builtins.attrNames scoped;
        fragment = {
          settings.formatter = scoped;
          # Evaluated excludes already contain treefmt-nix defaults iff the
          # project left enableDefaultExcludes on; the final eval disables
          # defaults globally, so each project's opt-out survives exactly.
          settings.excludes = map (scopePattern project.relPath) (settings.excludes or []);
        };
        # Unscoped policy snapshot for local-vs-global equivalence checks.
        policy = lib.mapAttrs (_: formatter: {
          inherit (formatter) command;
          options = formatter.options or [];
          includes = formatter.includes or ["*"];
          excludes = formatter.excludes or [];
        }) formatters;
      };

    scoped = builtins.seq _slugCheck (builtins.seq _overlapCheck (map scopedOne normalized));

    evalResult = treefmt-nix.lib.evalModule pkgs {
      imports =
        (map (entry: entry.fragment) scoped)
        ++ [
          {
            enableDefaultExcludes = false;
            # Project fragments carry no root of their own.
            projectRootFile = "flake.nix";
          }
        ];
    };

    baselineNames = lib.unique (lib.concatMap
      (entry: map (formatter: lib.removePrefix "${slugOf entry.relPath}-" formatter) entry.formatterNames)
      scoped);
    baselines = lib.genAttrs baselineNames (baselineCommand treefmt-nix pkgs);

    classify = entry: tool: command:
      if builtins.elem tool entry.centralNames
      then "central"
      else if baselines.${tool} or null != null && command == baselines.${tool}
      then "shared-pkgs"
      else "project-override";

    report = {
      projects = map (entry: {
        inherit (entry) name relPath;
        formatters = map (scopedName: let
            tool = lib.removePrefix "${slugOf entry.relPath}-" scopedName;
            command = evalResult.config.settings.formatter.${scopedName}.command;
          in {
            name = scopedName;
            inherit tool command;
            source = classify entry tool command;
          })
          entry.formatterNames;
      }) scoped;
    };

    _force = builtins.seq _slugCheck (builtins.seq _overlapCheck
      (builtins.deepSeq (map (entry: entry.formatterNames) scoped) true));
  in
    builtins.seq _force {inherit evalResult report;};
in {
  inherit validateRelPath scopePattern compose;
}
