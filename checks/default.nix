{
  pkgs,
  lib,
  harborOpencode,
  nixpkgs,
}: let
  merged = lib.devShell.merge [
    {
      packages = [pkgs.hello];
      env.A = "1";
      shellHook = "echo a";
    }
    {
      packages = [pkgs.jq];
      env.A = "2";
      shellHook = "echo b";
    }
  ];
  helloShell = lib.devShell.mkShell {
    inherit pkgs;
    packages = [pkgs.hello];
    env.HELLO_SHELL = "1";
    extraShellHook = "true";
  };
  derivationManifest = let
    fixture =
      pkgs.runCommand "harbor-meta-derivation-manifest-fixture" {
        outputs = ["out" "dev"];
      } ''
        mkdir -p "$out" "$dev"
      '';
  in
    lib.flake.mkDerivationManifest {
      inherit (pkgs.stdenv.hostPlatform) system;
      targets = {
        default = fixture;
        dev = fixture.dev;
        multiple = "${fixture}${fixture.dev}";
      };
    };
  staticTarget = builtins.tryEval (builtins.deepSeq (lib.flake.mkDerivationManifest {
      inherit (pkgs.stdenv.hostPlatform) system;
      targets.static = "/tmp/static";
    })
    true);
  ambiguousTarget = builtins.tryEval (builtins.deepSeq (lib.flake.mkDerivationManifest {
      inherit (pkgs.stdenv.hostPlatform) system;
      targets.ambiguous = "${pkgs.hello}${pkgs.jq}";
    })
    true);
in
  assert merged.env.A == "2";
  assert builtins.length merged.packages == 2;
  assert pkgs.lib.hasInfix "echo a" merged.shellHook;
  assert pkgs.lib.hasInfix "echo b" merged.shellHook; {
    dev-shell-hello = lib.devShellTests.mkCheck {
      inherit pkgs;
      name = "harbor-meta-dev-shell-hello";
      shell = helloShell;
      commands = ["hello"];
      env.HELLO_SHELL = "1";
      hookContains = ["true"];
      runHook = true;
    };

    stub-template = lib.templateTests.mkCheck {
      inherit pkgs;
      inherit (pkgs.stdenv.hostPlatform) system;
      flakeNix = ../tests/fixtures/stub-template/flake.nix;
      inputs = {inherit nixpkgs;};
      requiredFiles = ["flake.nix"];
      commands = ["hello"];
      env.STUB_SHELL = "1";
      hookContains = ["echo stub"];
      inherit (lib) devShellTests;
    };

    opencode-configs = pkgs.runCommand "harbor-meta-opencode-configs" {} ''
      cat > rust.json <<'EOF'
      ${lib.opencode.configText "rust"}
      EOF
      cat > python.json <<'EOF'
      ${lib.opencode.configText "python"}
      EOF
      cat > rust-openpencil.json <<'EOF'
      ${lib.opencode.configTextFor {
        kind = "rust";
        openpencil = true;
      }}
      EOF
      grep -q rust-analyzer rust.json
      grep -q nixd rust.json
      grep -q taplo rust.json
      ! grep -q openpencil rust.json
      grep -q basedpyright-langserver python.json
      grep -q '"pyright":{"disabled":true}' python.json
      grep -q '"ruff"' python.json
      grep -q openpencil-desktop rust-openpencil.json
      ! grep -q '"openpencil_*":"deny"' rust-openpencil.json
      ! grep -q '"mode":"subagent"' rust-openpencil.json
      grep -q rust-analyzer rust-openpencil.json
      mkdir -p $out
      echo ok > $out/result
    '';

    harbor-opencode-sync-check = pkgs.runCommand "harbor-meta-opencode-sync-check" {} ''
      export PATH=${harborOpencode}/bin:$PATH
      mkdir -p project
      touch project/Cargo.toml
      harbor-opencode sync --kind detect --root project
      harbor-opencode check --kind detect --root project
      grep -q rust-analyzer project/.opencode/opencode.jsonc
      ! grep -q openpencil project/.opencode/opencode.jsonc
      harbor-opencode sync --kind detect --openpencil --root project
      harbor-opencode check --kind detect --openpencil --root project
      grep -q openpencil-desktop project/.opencode/opencode.jsonc
      ! grep -q '"mode":"subagent"' project/.opencode/opencode.jsonc
      mkdir -p $out
      echo ok > $out/result
    '';

    package-tests-plan-shape = let
      builder = lib.packageTests.mkArtifactBuilder {
        kind = "chocolatey-builder";
        packageName = "demo";
        version = "1.0.0";
        output = "${pkgs.emptyDirectory}/demo.1.0.0.nupkg";
      };
      p = lib.packageTests.mkPlan {
        kind = "generic";
        packageName = "demo";
        version = "1.0.0";
        artifacts = [
          {
            name = "demo.tar.gz";
            path = "${pkgs.emptyDirectory}/demo.tar.gz";
          }
        ];
        install.command = "install demo";
        verify = [
          {command = "demo --version";}
        ];
      };
      w = lib.packageTests.mkWindowsPlan {
        packageName = "demo";
        version = "1.0.0";
        artifacts = [
          {
            name = "demo.zip";
            path = "${pkgs.emptyDirectory}/demo.zip";
          }
        ];
        installPowerShell = "Write-Host install";
        verifyPowerShell = ["Write-Host verify"];
      };
      c = lib.packageTests.mkChocolateyVagrantPlan {
        packageName = "demo";
        version = "1.0.0";
        nupkg = builder.output;
        inherit builder;
      };
    in
      assert p.hierarchy == ["generic" "generic"];
      assert w.hierarchy == ["generic" "windows" "windows"];
      assert c.builderRef == builder.ref;
      assert c.hierarchy == ["generic-builder" "windows-builder" "chocolatey-builder" "generic" "windows" "chocolatey-vagrant"];
        pkgs.runCommand "harbor-meta-package-tests-plan-shape" {} ''
          mkdir -p $out
          echo ok > $out/result
        '';

    package-tests-validation = let
      badBuilder = builtins.tryEval (lib.packageTests.mkArtifactBuilder {
        kind = "bad-builder";
        packageName = "demo";
        version = "1.0.0";
        output = "${pkgs.emptyDirectory}/demo";
      });
      badRunner = builtins.tryEval (lib.packageTests.mkRunnerBuilder {
        kind = "bad-runner-builder";
        packageName = "demo";
        plan = {};
        runner = "";
      });
      badKind = builtins.tryEval (lib.packageTests.mkPlan {
        kind = "bogus";
        packageName = "demo";
        version = "1.0.0";
        artifacts = [
          {
            name = "demo.tar.gz";
            path = "${pkgs.emptyDirectory}/demo.tar.gz";
          }
        ];
        install.command = "install demo";
      });
      badChoco = builtins.tryEval (lib.packageTests.mkChocolateyVagrantPlan {
        packageName = "Bad_Name";
        version = "1.0.0";
        nupkg = "${pkgs.emptyDirectory}/Bad_Name.1.0.0.nupkg";
      });
      badSource = builtins.tryEval (lib.packageTests.mkChocolateyVagrantPlan {
        packageName = "demo";
        version = "1.0.0";
        nupkg = "${pkgs.emptyDirectory}/demo.1.0.0.nupkg";
        source = "/packages";
      });
    in
      assert !badBuilder.success;
      assert !badRunner.success;
      assert !badKind.success;
      assert !badChoco.success;
      assert !badSource.success;
        pkgs.runCommand "harbor-meta-package-tests-validation" {} ''
          mkdir -p $out
          echo ok > $out/result
        '';

    package-tests-chocolatey-vagrant-render = let
      builder = lib.packageTests.mkArtifactBuilder {
        kind = "chocolatey-builder";
        packageName = "demo";
        version = "1.0.0";
        output = "${pkgs.emptyDirectory}/demo.1.0.0.nupkg";
      };
      plan = lib.packageTests.mkChocolateyVagrantPlan {
        packageName = "demo";
        version = "1.0.0";
        nupkg = builder.output;
        inherit builder;
        verifyPowerShell = ["demo --version"];
      };
      rendered = lib.packageTests.mkPackageTestRunner {inherit pkgs plan;};
      vagrantfile = lib.packageTests.renderVagrantfile plan;
      bundle = lib.packageTests.mkBuildTestBundle {
        artifactBuilder = builder;
        inherit plan;
        runnerBuilder = rendered.runnerBuilder;
      };
    in
      assert pkgs.lib.hasInfix "chocolatey/test-environment" vagrantfile;
      assert pkgs.lib.hasInfix ''config.vm.synced_folder "packages", "/packages"'' vagrantfile;
      assert pkgs.lib.hasInfix ''v.customize ["modifyvm", :id, "--memory", "6144"]'' vagrantfile;
      assert pkgs.lib.hasInfix ''v.customize ["modifyvm", :id, "--cpus", "4"]'' vagrantfile;
      assert pkgs.lib.hasInfix "choco install demo --version 1.0.0 --source C:\\packages" vagrantfile;
      assert rendered.runnerBuilder.kind == "chocolatey-vagrant-runner-builder";
      assert bundle.hierarchy == ["generic-builder" "windows-builder" "chocolatey-builder" "generic" "windows" "chocolatey-vagrant" "generic-runner-builder" "chocolatey-vagrant-runner-builder"];
        pkgs.runCommand "harbor-meta-package-tests-chocolatey-vagrant-render" {} ''
          test -f ${rendered.planJson}
          test -x ${rendered.runner}/bin/package-test-demo
          grep -q '"kind":"chocolatey-vagrant"' ${rendered.planJson}
          grep -q '"builderRef":"chocolatey-builder:demo:1.0.0"' ${rendered.planJson}
          grep -q 'vagrant up --provider=virtualbox' ${rendered.runner}/bin/package-test-demo
          mkdir -p $out
          echo ok > $out/result
        '';

    derivation-manifest-contract = assert derivationManifest.schemaVersion == 1;
    assert derivationManifest.system == pkgs.stdenv.hostPlatform.system;
    assert derivationManifest.targets.default.outputs == ["out"];
    assert derivationManifest.targets.dev.outputs == ["dev"];
    assert derivationManifest.targets.multiple.outputs == ["dev" "out"];
    assert builtins.getContext (builtins.toJSON derivationManifest) == {};
    assert !staticTarget.success;
    assert !ambiguousTarget.success;
      pkgs.runCommand "harbor-meta-derivation-manifest-contract" {} ''
        touch "$out"
      '';

    # Fail if flake inputs ever point at retired forge mirrors again
    # (fleet migrated to github.com/caniko/*). sourceUrl package metadata
    # is informational only, never fetched, so it is excluded.
    site-host-pinning =
      pkgs.runCommand "harbor-meta-site-host-pinning" {
        rootFlakeNix = ../flake.nix;
        rootFlakeLock = ../flake.lock;
        siteFlakeNix = ../site/flake.nix;
        siteFlakeLock = ../site/flake.lock;
      } ''
        if ${pkgs.gnugrep}/bin/grep -v sourceUrl "$rootFlakeNix" "$rootFlakeLock" "$siteFlakeNix" "$siteFlakeLock" \
          | ${pkgs.gnugrep}/bin/grep -E -q "codeberg|codefloe"; then
          echo "ERROR: retired forge host in flake inputs:" >&2
          ${pkgs.gnugrep}/bin/grep -v sourceUrl "$rootFlakeNix" "$rootFlakeLock" "$siteFlakeNix" "$siteFlakeLock" \
            | ${pkgs.gnugrep}/bin/grep -E -n "codeberg|codefloe" >&2 || true
          exit 1
        fi
        touch "$out"
      '';

    format-policy-contract = let
      fp = lib.opencode.formatPolicy;
      match = fp.matcher.match;
      docs = builtins.readFile ../docs/treefmt.md;
      raw = pkgs.lib.concatMap (entry: entry.patterns) fp.registry;
      firstToken = pattern: builtins.head (pkgs.lib.splitString " " pattern);
      policyOnly = builtins.toJSON (lib.opencode.mkConfig {});
      defaultedKind = builtins.toJSON (lib.opencode.mkConfig {kind = "none";});
      withExtra = builtins.toJSON (lib.opencode.mkConfig {extraFormatDenies = ["myfmt *"];});
      withoutPolicy = builtins.toJSON (lib.opencode.mkConfig {formatPermissions = false;});
      rustJson = builtins.toJSON (lib.opencode.mkConfig {kind = "rust";});
    in
      # Registry shape: every base pattern starts with a literal command name.
      # A broad glob like `*fmt *` (or a wildcard-bearing first token) would
      # deny unrelated commands; the env/store twins are generated, never
      # registered by hand.
      assert builtins.all (pattern: !(pkgs.lib.hasPrefix "*" pattern)) raw;
      assert builtins.all (pattern: !(pkgs.lib.hasInfix "*" (firstToken pattern))) raw;
      assert builtins.length raw == builtins.length (pkgs.lib.unique raw);
      # Doc coverage: every registry pattern appears verbatim in
      # docs/treefmt.md's Agent Formatter Policy table.
      assert builtins.all (pattern: pkgs.lib.hasInfix pattern docs) fp.patterns;
      # Glob -> POSIX replay of the deployed matcher semantics
      # (caniko/opencode@f18083c78e packages/core/src/util/wildcard.ts:
      # escape ERE metachars, `*` -> `.*`, trailing ` .*` -> `( .*)?`,
      # anchored full match).
      assert match "alejandra *" "alejandra --check .";
      assert match "alejandra *" "alejandra";
      assert !(match "alejandra *" "alejandrafmt --check .");
      assert !(match "alejandra *" "FOO=1 alejandra --check .");
      assert match "*=* alejandra *" "FOO=1 alejandra --check .";
      assert !(match "*=* alejandra *" "alejandra --check .");
      assert match "/nix/store/*/bin/alejandra *" "/nix/store/abc123-alejandra/bin/alejandra --check .";
      assert !(match "/nix/store/*/bin/alejandra *" "./result/bin/alejandra --check .");
      assert match "./result/bin/alejandra *" "./result/bin/alejandra --check .";
      assert match "cargo fmt *" "cargo fmt";
      assert !(match "cargo fmt *" "cargo build --release");
      assert match "shfmt -d *" "shfmt -d ./x.sh";
      assert match "ruff check *--fix*" "ruff check --fix .";
      assert match "ruff check *--fix*" "ruff check src --fix";
      assert !(match "ruff check *--fix*" "ruff check .");
      assert !(match "prettier *" "prettierx --write .");
      assert match "nix fmt *" "nix fmt";
      assert match "just --fmt *" "just --fmt --unstable";
      assert match "go fmt *" "go fmt ./...";
      # Rendered shapes: policy-only has no lsp block and carries the deny
      # fragment + identity marker; kind configs keep their lsp; no allow
      # values and no catch-all ever appear; extras get twin expansion; the
      # identity marker survives even with formatPermissions = false.
      assert !(pkgs.lib.hasInfix "\"lsp\"" policyOnly);
      assert policyOnly == defaultedKind;
      assert pkgs.lib.hasInfix "\"permission\"" policyOnly;
      assert pkgs.lib.hasInfix "\"${fp.marker}\":\"${fp.markerValue}\"" policyOnly;
      assert pkgs.lib.hasInfix "\"alejandra *\":\"deny\"" policyOnly;
      assert pkgs.lib.hasInfix "\"*=* alejandra *\":\"deny\"" policyOnly;
      assert pkgs.lib.hasInfix "\"/nix/store/*/bin/alejandra *\":\"deny\"" policyOnly;
      assert !(pkgs.lib.hasInfix ":\"allow\"" policyOnly);
      assert !(pkgs.lib.hasInfix "\"*\":\"deny\"" policyOnly);
      assert pkgs.lib.hasInfix "\"lsp\"" rustJson;
      assert pkgs.lib.hasInfix "\"myfmt *\":\"deny\"" withExtra;
      assert pkgs.lib.hasInfix "\"*=* myfmt *\":\"deny\"" withExtra;
      assert !(pkgs.lib.hasInfix "\"permission\"" withoutPolicy);
      assert pkgs.lib.hasInfix "\"${fp.marker}\":\"${fp.markerValue}\"" withoutPolicy;
        pkgs.runCommand "harbor-meta-format-policy-contract" {} ''
          mkdir -p "$out"
          echo ok > "$out/result"
        '';

    format-policy-render = let
      fp = lib.opencode.formatPolicy;
      denyGreps =
        pkgs.lib.concatMapStringsSep "\n" (pattern: ''
          grep -qF '"${pattern}":"deny"' rust.json
          grep -qF '"${pattern}":"deny"' none.json
          grep -qF '"*=* ${pattern}":"deny"' rust.json
        '')
        fp.patterns;
    in
      pkgs.runCommand "harbor-meta-format-policy-render" {
        rustConfig = lib.opencode.configText "rust";
        noneConfig = lib.opencode.configText "none";
        defaultedConfig = lib.opencode.configTextFor {};
        rustOpenpencilConfig = lib.opencode.configTextFor {
          kind = "rust";
          openpencil = true;
        };
        passAsFile = [
          "rustConfig"
          "noneConfig"
          "defaultedConfig"
          "rustOpenpencilConfig"
        ];
      } ''
        cp "$rustConfigPath" rust.json
        cp "$noneConfigPath" none.json
        cp "$defaultedConfigPath" defaulted.json
        cp "$rustOpenpencilConfigPath" rust-openpencil.json

        ${denyGreps}

        # Identity marker in every rendered shape (used by sync/refusal).
        grep -qF '"harbor.meta/opencode-config":"1"' rust.json
        grep -qF '"harbor.meta/opencode-config":"1"' none.json
        grep -qF '"harbor.meta/opencode-config":"1"' defaulted.json
        grep -qF '"harbor.meta/opencode-config":"1"' rust-openpencil.json

        # Deny-only: no allow anywhere, no catch-all key.
        ! grep -q ':"allow"' rust.json
        ! grep -q ':"allow"' none.json
        ! grep -q ':"allow"' rust-openpencil.json
        ! grep -qF '"*":"deny"' rust.json
        ! grep -qF '"*":"ask"' rust.json

        # Policy-only shapes carry no lsp block; kind shapes keep theirs.
        ! grep -q '"lsp"' none.json
        ! grep -q '"lsp"' defaulted.json
        grep -q '"lsp"' rust.json
        grep -q rust-analyzer rust.json

        # Openpencil and the format policy coexist in one document.
        grep -q openpencil-desktop rust-openpencil.json
        grep -qF '"alejandra *":"deny"' rust-openpencil.json
        ! grep -q '"mode":"subagent"' rust-openpencil.json

        mkdir -p "$out"
        echo ok > "$out/result"
      '';

    harbor-opencode-rollout-check = pkgs.runCommand "harbor-meta-opencode-rollout-check" {} ''
      export PATH=${harborOpencode}/bin:${pkgs.git}/bin:$PATH
      export HOME="$PWD"
      export GIT_CONFIG_GLOBAL="$PWD/gitconfig"
      export GIT_CONFIG_SYSTEM=/dev/null
      printf '[user]\n\temail = ci@example.com\n\tname = Harbor CI\n' > gitconfig

      for name in rustproj plainproj customproj dirtyproj; do
        mkdir -p "fleet/$name"
        git init -q "fleet/$name"
      done
      touch fleet/rustproj/Cargo.toml
      mkdir -p fleet/customproj/.opencode
      printf '{"$schema":"https://opencode.ai/config.json","custom":true}\n' \
        > fleet/customproj/.opencode/opencode.jsonc
      touch fleet/dirtyproj/unrelated-change.txt
      for name in rustproj plainproj customproj; do
        git -C "fleet/$name" add -A
        git -C "fleet/$name" commit -qm init
      done

      # First rollout must report the hand-written config and the dirty tree
      # without touching either — an exit 0 here would hide both.
      if harbor-opencode rollout --root fleet; then
        echo "rollout exited 0 despite a custom config and a dirty repo" >&2
        exit 1
      fi
      grep -q rust-analyzer fleet/rustproj/.opencode/opencode.jsonc
      grep -qF '"alejandra *":"deny"' fleet/rustproj/.opencode/opencode.jsonc
      grep -qF '"harbor.meta/opencode-config":"1"' fleet/rustproj/.opencode/opencode.jsonc
      ! grep -q '"lsp"' fleet/plainproj/.opencode/opencode.jsonc
      grep -qF '"alejandra *":"deny"' fleet/plainproj/.opencode/opencode.jsonc
      grep -q '"custom":true' fleet/customproj/.opencode/opencode.jsonc
      ! grep -qF 'harbor.meta/opencode-config' fleet/customproj/.opencode/opencode.jsonc
      test ! -f fleet/dirtyproj/.opencode/opencode.jsonc

      # --force replaces the custom config; the foreign dirt still blocks.
      if harbor-opencode rollout --root fleet --force; then
        echo "rollout exited 0 while a repo still has foreign dirt" >&2
        exit 1
      fi
      grep -qF '"alejandra *":"deny"' fleet/customproj/.opencode/opencode.jsonc
      test ! -f fleet/dirtyproj/.opencode/opencode.jsonc

      # Our own rendered config is not foreign dirt: synced repos keep
      # syncing, and a repo that loses its foreign change is picked up.
      rm fleet/dirtyproj/unrelated-change.txt
      harbor-opencode rollout --root fleet
      test -f fleet/dirtyproj/.opencode/opencode.jsonc

      # Read-only verification passes once every config is rendered.
      harbor-opencode rollout --root fleet --check

      # Explicit sync refuses a hand-written config without --force, then
      # succeeds with it; kind detection falls back to policy-only `none`.
      mkdir -p custom-solo/.opencode
      printf '{"custom":true}\n' > custom-solo/.opencode/opencode.jsonc
      if harbor-opencode sync --kind detect --root custom-solo; then
        echo "sync overwrote a custom config without --force" >&2
        exit 1
      fi
      grep -q '"custom":true' custom-solo/.opencode/opencode.jsonc
      harbor-opencode sync --kind detect --root custom-solo --force
      grep -qF '"alejandra *":"deny"' custom-solo/.opencode/opencode.jsonc
      ! grep -q '"lsp"' custom-solo/.opencode/opencode.jsonc

      mkdir -p "$out"
      echo ok > "$out/result"
    '';
  }
