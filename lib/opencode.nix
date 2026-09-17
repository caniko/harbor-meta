{lib}: let
  schema = "https://opencode.ai/config.json";

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

  mkConfig = {
    kind,
    openpencil ? false,
  }:
    {
      "$schema" = schema;
      lsp = lspForKind kind;
    }
    // lib.optionalAttrs openpencil {
      mcp.openpencil = {
        type = "local";
        command = ["openpencil-desktop" "--mcp" "{env:HOME}/.local/share/openpencil/agent.op"];
        enabled = true;
      };
    };

  configForKind = kind: mkConfig {inherit kind;};
in rec {
  inherit schema rustLsp pythonLsp lspForKind configForKind mkConfig;

  supportedKinds = ["rust" "python" "mixed"];

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
    else throw "harbor-meta.opencode: unsupported kind `${kind}`";

  checkKind = kind:
    lib.assertMsg (builtins.elem kind supportedKinds)
    "harbor-meta.opencode: kind must be one of ${lib.concatStringsSep ", " supportedKinds}, got `${kind}`";
}
