# harbor-meta

Shared harbor helpers for editor and agent tooling.

`harbor-meta` owns cross-language policy shared by the language harbors.

Dev shells are fragments `{ packages, env, shellHook }`. Language harbors merge
those fragments and render them with `lib.devShell.mkShell` (`pkgs.mkShell` by
default; Rust passes a `craneLib.devShell` builder). `lib.devShellTests` and
`lib.templateTests` evaluate harbor templates by importing their `flake.nix`
with the current flake inputs — no nested `nix` and no template lockfiles.

`lib.flake.mkDerivationManifest` records exact derivation paths and selected
outputs without retaining string context. Orchestrators can serialize that
manifest and realize the same derivations locally or on an explicitly selected
remote builder without changing store identity.

Opencode LSP discovery remains a separate surface: checked-in
`.opencode/opencode.jsonc` files declare the LSPs opencode may use, while each
project's direnv-powered harbor dev shell supplies the actual binaries.

## Usage

```bash
harbor-opencode sync --kind detect
harbor-opencode check --kind detect
harbor-opencode rollout --root /data/nvme0/can/Projects
```
