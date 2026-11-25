{lib}: let
  validGroup = group:
    lib.assertMsg (builtins.match "[A-Za-z_][A-Za-z0-9_.-]*" group != null)
    "Shared data read access requires a group name starting with a letter or underscore.";

  normalize = path: let
    parts = lib.splitString "/" path;
    literal =
      lib.hasPrefix "/" path
      && builtins.match ".*[[:cntrl:]].*" path == null
      && !(lib.any (char: lib.hasInfix char path) ["*" "?" "[" "%" "\\" "'" "\""])
      && !(builtins.elem ".." parts);
  in
    assert lib.assertMsg literal "Shared data read access requires an absolute literal path without '..': ${builtins.toJSON path}";
      "/" + lib.concatStringsSep "/" (builtins.filter (part: part != "" && part != ".") parts);

  mkSharedDataReadAccessRules = {
    group,
    traversePaths ? [],
    readPaths ? [],
  }: let
    read = lib.unique (map normalize readPaths);
    traverse = lib.subtractLists read (lib.unique (map normalize traversePaths));
    rule = kind: access: path: "${kind} ${builtins.replaceStrings [" "] ["\\x20"] path} - - - - g:${group}:${access}";
  in
    assert validGroup group;
      map (rule "a+" "r-x") traverse ++ map (rule "A+" "r-X") read;
in {
  inherit mkSharedDataReadAccessRules;

  mkSharedDataReadAccessConfig = {
    lib,
    group,
    members ? [],
    traversePaths ? [],
    readPaths ? [],
  }:
    assert validGroup group; {
      users.groups.${group} = {};
      users.users = lib.genAttrs (lib.unique members) (_: {extraGroups = [group];});
      systemd.tmpfiles.rules = mkSharedDataReadAccessRules {inherit group traversePaths readPaths;};
    };
}
