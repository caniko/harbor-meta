{
  nixpkgs,
  system,
  lib,
  module,
}: let
  inherit (lib) mkSharedDataReadAccessRules mkSharedDataReadAccessConfig;
  group = "shared-readers";
  traverseRule = "a+ /srv/shared - - - - g:${group}:r-x";
  readRule = "A+ /srv/shared/data - - - - g:${group}:r-X";
  archiveRule = "A+ /srv/shared/archive - - - - g:${group}:r-X";
  eval = modules:
    (nixpkgs.lib.nixosSystem {
      inherit system;
      modules =
        [
          module
          {
            system.stateVersion = "26.05";
            users.users.reader = {
              isSystemUser = true;
              group = "nogroup";
              extraGroups = ["users"];
            };
            users.users.auditor = {
              isSystemUser = true;
              group = "nogroup";
            };
          }
        ]
        ++ modules;
    }).config;
  baseline = eval [];
  disabled = eval [
    {harbor.sharedDataReadAccess.data.readPaths = ["/srv/shared/data"];}
  ];
  enabled = {
    harbor.sharedDataReadAccess.data = {
      enable = true;
      inherit group;
      members = ["reader"];
      traversePaths = ["/srv/shared"];
      readPaths = ["/srv/shared/data"];
    };
  };
  single = eval [enabled];
  dual = eval [
    enabled
    {
      harbor.sharedDataReadAccess.archive = {
        enable = true;
        inherit group;
        members = ["auditor"];
        traversePaths = ["/srv//shared/"];
        readPaths = ["/srv/shared/archive"];
      };
    }
  ];
  helperConfig = eval [
    ({lib, ...}:
      mkSharedDataReadAccessConfig {
        inherit lib group;
        members = ["reader" "reader"];
        readPaths = ["/srv/shared/data"];
      })
    ({lib, ...}:
      mkSharedDataReadAccessConfig {
        inherit lib group;
        members = ["auditor"];
        traversePaths = ["/srv/shared"];
      })
  ];
  accessRules = cfg: nixpkgs.lib.subtractLists baseline.systemd.tmpfiles.rules cfg.systemd.tmpfiles.rules;
  hasSameRules = cfg: expected: builtins.sort builtins.lessThan (accessRules cfg) == builtins.sort builtins.lessThan expected;
in
  assert mkSharedDataReadAccessRules {inherit group;} == [];
  assert mkSharedDataReadAccessRules {
    inherit group;
    traversePaths = ["/srv/shared" "/srv//shared/." "/srv/shared/data"];
    readPaths = ["/srv/shared/data/" "/srv/shared/data"];
  }
  == [traverseRule readRule];
  assert mkSharedDataReadAccessRules {
    inherit group;
    readPaths = ["/srv/shared/read only"];
  }
  == ["A+ /srv/shared/read\\x20only - - - - g:${group}:r-X"];
  assert builtins.all (path:
    !(builtins.tryEval (builtins.deepSeq (mkSharedDataReadAccessRules {
        inherit group;
        readPaths = [path];
      })
      true)).success) ["" "relative" "/srv/../etc" "/srv/*" "/srv/%t" "/srv/a\nb"];
  assert !(builtins.tryEval (mkSharedDataReadAccessRules {group = "readers:rwx,g:root";})).success;
  assert !(builtins.hasAttr group disabled.users.groups);
  assert disabled.users.users.reader.extraGroups == baseline.users.users.reader.extraGroups;
  assert accessRules disabled == [];
  assert builtins.hasAttr group single.users.groups;
  assert builtins.elem group single.users.users.reader.extraGroups;
  assert builtins.elem "users" single.users.users.reader.extraGroups;
  assert hasSameRules single [traverseRule readRule];
  assert hasSameRules dual [traverseRule readRule archiveRule];
  assert hasSameRules helperConfig [traverseRule readRule];
  assert builtins.all (cfg: builtins.sort builtins.lessThan cfg.users.groups.${group}.members == ["auditor" "reader"]) [dual helperConfig]; true
