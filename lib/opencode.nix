{lib}: let
  schema = "https://opencode.ai/config.json";
  formatPolicy = import ./format-policy.nix {inherit lib;};

  rustLsp = {
    rust.command = ["rust-analyzer"];
    nixd.command = ["nixd"];
    taplo = {
      command = ["taplo" "lsp" "stdio"];
      extensions = [".toml"];
    };
  };

  pythonLsp = {
    pyright.disabled = true;
    basedpyright = {
      command = ["basedpyright-langserver" "--stdio"];
      extensions = [".py" ".pyi"];
    };
    ruff = {
      command = ["ruff" "server"];
      extensions = [".py" ".pyi"];
    };
  };

  lspForKind = kind:
    if kind == "rust"
    then rustLsp
    else if kind == "python"
    then pythonLsp
    else if kind == "mixed"
    then rustLsp // pythonLsp
    else throw "harbor-meta.opencode: unsupported kind `${kind}`";

  # `kind = null` (the default) renders a policy-only config: the format
  # permissions without any `lsp` block. `"none"` is the explicit spelling of
  # the same shape for CLI use. `formatPermissions` toggles the deny fragment,
  # `extraFormatDenies` appends project-local patterns (the same twin
  # expansion applies to them), and `storePathTwins` gates the
  # `/nix/store/*/bin/…` and `./result/bin/…` variants. The
  # `formatPolicy.marker` identity key is written unconditionally so
  # harbor-opencode can always recognise its own output.
  mkConfig = {
    kind ? null,
    openpencil ? false,
    formatPermissions ? true,
    extraFormatDenies ? [],
    storePathTwins ? true,
  }:
    {
      "$schema" = schema;
      "${formatPolicy.marker}" = formatPolicy.markerValue;
    }
    // lib.optionalAttrs (kind != null && kind != "none") {lsp = lspForKind kind;}
    // lib.optionalAttrs openpencil {
      mcp.openpencil = {
        type = "local";
        command = ["openpencil-desktop" "--mcp" "{env:HOME}/.local/share/openpencil/agent.op"];
        enabled = true;
      };
    }
    // lib.optionalAttrs formatPermissions {
      permission.bash = formatPolicy.bashDenies {
        inherit storePathTwins;
        extra = extraFormatDenies;
      };
    };

  configForKind = kind: mkConfig {inherit kind;};
in rec {
  inherit
    schema
    rustLsp
    pythonLsp
    lspForKind
    configForKind
    mkConfig
    formatPolicy
    ;

  supportedKinds = ["rust" "python" "mixed" "none"];

  configText = kind:
    builtins.toJSON (configForKind kind) + "\n";

  configTextFor = args:
    builtins.toJSON (mkConfig args) + "\n";

  configPath = ".opencode/opencode.jsonc";

  packagesForKind = pkgs: kind:
    if kind == "rust"
    then [pkgs.nixd pkgs.taplo]
    else if kind == "python"
    then [pkgs.basedpyright pkgs.ruff]
    else if kind == "mixed"
    then [pkgs.nixd pkgs.taplo pkgs.basedpyright pkgs.ruff]
    else if kind == "none"
    then []
    else throw "harbor-meta.opencode: unsupported kind `${kind}`";

  checkKind = kind:
    lib.assertMsg (builtins.elem kind supportedKinds)
    "harbor-meta.opencode: kind must be one of ${lib.concatStringsSep ", " supportedKinds}, got `${kind}`";
}
