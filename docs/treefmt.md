# Modular Formatting

Harbor exports plain treefmt-nix modules under `treefmtModules`. Import only
the languages you need. Language modules do not import a base module, select
a project root, install toolchain overlays, or exclude consumer directories.

| Owner | Export | Formatter |
| --- | --- | --- |
| harbor-meta | `treefmtModules.nix` | Alejandra |
| harbor-meta | `treefmtModules.toml` | Taplo |
| harbor-rs | `treefmtModules.rust` | rustfmt |
| harbor-js | `treefmtModules.javascript` | Prettier for JS, TS, and JSON |
| harbor-py | `treefmtModules.python` | Ruff format, not lint/fix |
| harbor-android | `treefmtModules.java` | google-java-format |
| harbor-android | `treefmtModules.kotlin` | ktfmt |
| harbor-eth | `treefmtModules.solidity` | Forge fmt |
| harbor-tex | `treefmtModules.latex` | latexindent |

`harbor-db` and `harbor-sol` compose the Rust module, not copies of it.
`harbor-ntt` formats its Nix/TOML infrastructure; NTT consumers explicitly
select Rust, JS, and Solidity modules for their sources. The input-free
`harbor-macos-sdk-pin` is a data flake, not a toolchain Harbor, and stays
input-free.

## Consumer Composition

Use one treefmt-nix evaluator and one consumer package set. For example,
inside a per-system flake output:

```nix
let
  treefmt = inputs.treefmt-nix.lib.evalModule pkgs {
    imports = [
      inputs.harbor-meta.treefmtModules.nix
      inputs.harbor-meta.treefmtModules.toml
      inputs.harbor-rs.treefmtModules.rust
      inputs.harbor-js.treefmtModules.javascript
    ];
    projectRootFile = "flake.nix";
    settings.global.excludes = ["generated/**"];
    programs.rustfmt.package = toolchain.rustToolchain;
    programs.rustfmt.edition = "2024";
  };
in {
  formatter = treefmt.config.build.wrapper;
  checks.formatting = treefmt.config.build.check self;
}
```

The Rust module leaves package and edition selection to treefmt-nix defaults
unless the consumer overrides them. Rust templates retain their explicit
editions and toolchains. A repository with several Rust editions should
configure path-specific formatters instead of assuming one global edition.

Prettier does not claim TOML, Nix, Markdown, or YAML files. Enable those
separately if needed. Keep generated-file exclusions in the consumer;
the JS template preserves its `.crow/**` exclusion there.

The repository formatter outputs and the Rust, Python, JavaScript, TeX,
Android, Ethereum, and Solana templates use explicit module composition.
Existing Simit-managed consumers are not rewritten by this change.

## Direnv

Load a consumer's dev shell with its `.envrc` (`use flake . || return 1`).
The configured treefmt hook declares `package = treefmtWrapper`, so shells
including `pre-commit-check.enabledPackages` put the same configured wrapper
on `PATH` for interactive use. Projects without that hook plumbing must add
their formatter output to their shell's packages explicitly; Canix's
configure shell does this directly.

```sh
treefmt
treefmt --fail-on-change
```

Outside an interactive direnv-enabled shell, use `direnv exec . treefmt`.
The formatter itself invokes neither Nix nor direnv. Loading or refreshing
the dev shell still evaluates Nix and may realize dependencies; this is not
a promise that a cold direnv load is build-free. Do not automatically allow
new `.envrc` files on behalf of the operator.

## Checks

`harbor-meta` exposes `checks.<system>.treefmt-modules`, testing independence,
import-order and duplicate-import equivalence, consumer exclusions, real
Nix/TOML formatting, and a second uncached pass for idempotence.
`harbor-rs` exposes the same check name for Rust-only isolation, consumer
toolchain/edition overrides, mixed Nix/Rust/TOML composition, and formatting
idempotence. JS, Python and TeX template checks inspect evaluated formatter
settings rather than source-string declarations.

```sh
nix build .#checks.x86_64-linux.treefmt-modules --no-link
```

## Coordinated Rollout

These exports must exist in each locked Harbor input before a consumer can
evaluate its new composition. Publish the scoped harbor-meta changes first,
then update dependent Harbor locks. Publish harbor-rs before updating the
explicit Rust pin in harbor-db and the Rust input in harbor-sol. Do not
commit local `path:` overrides or lock unrelated dirty changes into a release.

During development, validate with temporary overrides and no lock writes:

```sh
# From a sibling harbor-rs checkout:
nix build .#checks.x86_64-linux.treefmt-modules --no-link \
  --override-input harbor-meta path:../harbor-meta --no-write-lock-file
```

Run module evaluations on each repository's declared systems; building a
Linux formatter does not prove Darwin execution. Lock refreshes and runtime
checks are required before calling the coordinated rollout complete.
