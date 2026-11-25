{
  config,
  lib,
  ...
}: let
  inherit (import ../lib/shared-data-read-access.nix {inherit lib;}) mkSharedDataReadAccessConfig;
  inherit (lib) mkEnableOption mkMerge mkOption types;

  stringList = description:
    mkOption {
      type = types.listOf types.str;
      default = [];
      inherit description;
    };

  grants = map (grant:
    mkSharedDataReadAccessConfig {
      inherit lib;
      inherit (grant) group members traversePaths readPaths;
    })
  (builtins.filter (grant: grant.enable) (builtins.attrValues config.harbor.sharedDataReadAccess));
in {
  options.harbor.sharedDataReadAccess = mkOption {
    type = types.attrsOf (types.submodule {
      options = {
        enable = mkEnableOption "shared data read access";
        group = mkOption {
          type = types.str;
          description = "Group to grant read access to.";
        };
        members = stringList "Existing NixOS users to add to the access group.";
        traversePaths = stringList "Absolute literal directory paths to grant non-recursive read and search access to.";
        readPaths = stringList "Absolute literal paths to grant recursive read and conditional search access to.";
      };
    });
    default = {};
    description = "Named grants for group-based read access to existing data via tmpfiles ACLs.";
  };

  # Keep the top-level config keys static while computing grants from options.
  config = {
    users = mkMerge (map (grant: grant.users) grants);
    systemd.tmpfiles.rules = lib.unique (lib.concatMap (grant: grant.systemd.tmpfiles.rules) grants);
  };
}
