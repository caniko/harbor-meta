{
  pkgs,
  lib,
  harborOpencode,
}: {
  opencode-configs = pkgs.runCommand "meta-harbor-opencode-configs" {} ''
    cat > rust.json <<'EOF'
    ${lib.opencode.configText "rust"}
    EOF
    cat > python.json <<'EOF'
    ${lib.opencode.configText "python"}
    EOF
    grep -q rust-analyzer rust.json
    grep -q nixd rust.json
    grep -q taplo rust.json
    grep -q basedpyright-langserver python.json
    grep -q '"pyright":{"disabled":true}' python.json
    grep -q '"ruff"' python.json
    mkdir -p $out
    echo ok > $out/result
  '';

  harbor-opencode-sync-check = pkgs.runCommand "meta-harbor-opencode-sync-check" {} ''
    export PATH=${harborOpencode}/bin:$PATH
    mkdir -p project
    touch project/Cargo.toml
    harbor-opencode sync --kind detect --root project
    harbor-opencode check --kind detect --root project
    grep -q rust-analyzer project/.opencode/opencode.jsonc
    mkdir -p $out
    echo ok > $out/result
  '';
}
