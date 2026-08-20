# meta-harbor

Shared harbor helpers for editor and agent tooling.

`meta-harbor` owns cross-language policy shared by the language harbors.

Dev shells are fragments `{ packages, env, shellHook }`. Language harbors merge
those fragments and render them with `lib.devShell.mkShell` (`pkgs.mkShell` by
default; Rust passes a `craneLib.devShell` builder). `lib.devShellTests` and
`lib.templateTests` evaluate harbor templates by importing their `flake.nix`
with the current flake inputs — no nested `nix` and no template lockfiles.

Opencode LSP discovery remains a separate surface: checked-in
`.opencode/opencode.jsonc` files declare the LSPs opencode may use, while each
project's direnv-powered harbor dev shell supplies the actual binaries.

## Usage

```bash
harbor-opencode sync --kind detect
harbor-opencode check --kind detect
harbor-opencode rollout --root /data/nvme0/can/Projects
```
