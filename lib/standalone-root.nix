# Standalone stand-in for the harbor superproject's root flake.
#
# Component repositories evaluate both as harbor submodules (harbor's root
# passes itself as `harborRoot`) and on their own. Standalone, build the subset
# of the root outputs from the component flakes at hand, with harbor's names:
# `lib.<namespace>` and `<component>-<name>` modules, templates and packages.
#
#   harborRoot = outputArgs.harborRoot or harbor-meta.lib.standaloneRoot {
#     core = harbor-meta;
#     python = self;
#   };
{lib}: components: let
  names = builtins.attrNames components;
  prefix = name: lib.mapAttrs' (key: lib.nameValuePair "${name}-${key}");
  collectModules = output: lib.foldl' (acc: name: acc // prefix name (components.${name}.${output} or {})) {} names;
  collect = output: let
    systems = lib.unique (lib.concatMap (name: builtins.attrNames (components.${name}.${output} or {})) names);
  in
    lib.genAttrs systems (system: lib.foldl' (acc: name: acc // prefix name (components.${name}.${output}.${system} or {})) {} names);
  libOf = name: lib.optionalAttrs (components ? ${name}) {${name} = components.${name}.lib or {};};
  namespaces = {
    projects = "docs";
    evm = "blockchain";
    solana = "blockchain";
    ntt = "blockchain";
  };
in {
  lib =
    lib.foldl' (acc: name: acc // libOf name) {} (lib.subtractLists (builtins.attrNames namespaces ++ ["macos-sdk"]) names)
    // lib.optionalAttrs (components ? projects) {docs = components.projects.lib or {};}
    // lib.optionalAttrs (lib.any (name: components ? ${name}) ["evm" "solana" "ntt"]) {
      blockchain = lib.foldl' (acc: name: acc // libOf name) {} ["evm" "solana" "ntt"];
    }
    // lib.optionalAttrs (components ? macos-sdk) {pins.macosSdk = components.macos-sdk;};
  nixosModules = collectModules "nixosModules";
  homeManagerModules = collectModules "homeManagerModules";
  treefmtModules = collectModules "treefmtModules";
  templates = collectModules "templates";
  packages = collect "packages";
}
