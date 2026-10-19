{
  lib,
  mkJustScript,
  mkResolver,
  coverage,
}: {
  pkgs,
  treefmt-nix,
  config,
}: let
  mkJustPolicy = mkResolver {inherit pkgs;};
  justPolicy = mkJustPolicy config;
  inherit (justPolicy) justProgramCfg justContract expectedBashExe resolveDirect;
  inherit (justContract) expectedJustExe expectedJustScript;
  rootFormatters = config.treefmt.settings.formatter;
  programInvocations =
    (coverage {
      formatters = rootFormatters;
      inherit resolveDirect;
      bashMap = {};
    }).programInvocations;
  attempt = name: entry: builtins.tryEval (builtins.deepSeq (resolveDirect name entry) true);
  direct = resolveDirect "fixture-direct" {
    command = "/nix/store/abc-alejandra/bin/alejandra";
    options = ["--check" "."];
  };
  just = resolveDirect "just" rootFormatters.just;
  # Evaluate the real, pinned treefmt module. Synthesizing fixture wrappers
  # with mkJustScript would let a broken predictor certify its own output.
  evalTreefmt = module: treefmt-nix.lib.evalModule pkgs module;
  standalone = evalTreefmt {programs.just.enable = true;};
  altJustPackage = pkgs.hello;
  overridden = evalTreefmt {
    programs.just = {
      enable = true;
      package = altJustPackage;
    };
  };
  indented = evalTreefmt {
    programs.just = {
      enable = true;
      indentation = "  ";
    };
  };
  overridePolicy = mkJustPolicy {treefmt = overridden.config;};
  overrideContract = overridePolicy.justContract;
  overrideWrapper = overridden.config.settings.formatter.just;
  overrideResolved = overridePolicy.resolveDirect "just" overrideWrapper;
  indentationPolicy = mkJustPolicy {treefmt = indented.config;};
  indentationContract = indentationPolicy.justContract;
  indentationWrapper = indented.config.settings.formatter.just;
  wrongNamespace = {
    programs.just = {
      package = altJustPackage;
      indentation = null;
    };
  };
  # WHNF detects the missing namespace without deep-forcing a derivation.
  wrongNamespaceTry = builtins.tryEval (builtins.seq (mkJustPolicy wrongNamespace).justProgramCfg true);
  baseAssertions = assert lib.assertMsg (rootFormatters.just.command == expectedBashExe) "resolver fixture: actual just command is not the pinned bash exe";
  assert lib.assertMsg (map builtins.toString rootFormatters.just.options == ["-euc" expectedJustScript "--"]) "resolver fixture: actual just options do not match the pinned wrapper script";
  assert lib.assertMsg (direct
    == {
      head = "/nix/store/abc-alejandra/bin/alejandra";
      rest = "--check .";
    }) "resolver fixture: direct string shape changed";
  assert lib.assertMsg (resolveDirect "fixture-direct" {
      command = [direct.head];
      options = ["--check" "."];
    }
    == direct) "resolver fixture: list form must equal string form";
  assert lib.assertMsg (just
    == {
      head = expectedJustExe;
      rest = "--fmt --unstable";
    }) "resolver fixture: actual just entry must resolve to the evaluated exact executable";
  assert lib.assertMsg (resolveDirect "just" {command = [expectedBashExe "-euc" expectedJustScript "--"];} == just) "resolver fixture: supported list-form just wrapper must use the same adapter";
  assert lib.assertMsg (resolveDirect "just" {
      command = expectedBashExe;
      options = ["-euc" expectedJustScript "--"];
    }
    == just) "resolver fixture: string-command just form must use the same adapter";
  assert lib.assertMsg ((config.programs.just or null) == null) "resolver fixture: wrong-namespace config.programs.just must be absent so fallback coincidence is visible";
  assert lib.assertMsg (standalone.config.settings.formatter.just == rootFormatters.just) "resolver fixture: standalone treefmt evalModule must reproduce the production just entry";
  assert lib.assertMsg ((mkJustPolicy {treefmt = standalone.config;}).justProgramCfg.package == justProgramCfg.package) "resolver fixture: standalone default program config must match the production one";
  assert lib.assertMsg (overrideWrapper != rootFormatters.just) "resolver fixture: package override must change the evaluated wrapper";
  assert lib.assertMsg (overrideWrapper.command == expectedBashExe) "resolver fixture: upstream module must emit the pinned bash command under package override";
  assert lib.assertMsg (overrideWrapper.options == ["-euc" overrideContract.expectedJustScript "--"]) "resolver fixture: upstream program module must emit exactly the wrapper our contract predicts (mkJustScript parity)";
  assert lib.assertMsg (overrideContract.expectedJustExe == lib.getExe altJustPackage) "resolver fixture: overridden contract must read the overridden package";
  assert lib.assertMsg (overrideContract.expectedJustExe != expectedJustExe && overrideContract.expectedJustScript != expectedJustScript) "resolver fixture: overridden package must change the evaluated executable and script";
  assert lib.assertMsg (overrideResolved
    == {
      head = overrideContract.expectedJustExe;
      rest = "--fmt --unstable";
    }) "resolver fixture: production adapter must accept its own evaluated override wrapper";
  assert lib.assertMsg (!(builtins.tryEval (builtins.deepSeq (overridePolicy.resolveDirect "just" rootFormatters.just) true)).success) "resolver fixture: overridden contract must reject the default wrapper";
  assert lib.assertMsg (!wrongNamespaceTry.success) "resolver fixture: selector must fail closed without the treefmt namespace";
  assert lib.assertMsg ((mkJustPolicy {treefmt = wrongNamespace;}).justProgramCfg.package == altJustPackage) "resolver fixture: selector must accept the wrapped namespace";
  assert lib.assertMsg (lib.hasInfix "--indentation" indentationContract.expectedJustScript && indentationContract.expectedJustScript != expectedJustScript) "resolver fixture: indented contract must carry --indentation in the evaluated script";
  assert lib.assertMsg (indentationWrapper != rootFormatters.just && indentationWrapper.options == ["-euc" indentationContract.expectedJustScript "--"]) "resolver fixture: upstream program module must emit exactly the indented wrapper our contract predicts";
  assert lib.assertMsg (lib.hasInfix (lib.escapeShellArgs ["--indentation" "  "]) (builtins.elemAt indentationWrapper.options 1)) "resolver fixture: evaluated indented wrapper must carry the real --indentation flag";
  assert lib.assertMsg (!(builtins.tryEval (builtins.deepSeq (indentationPolicy.resolveDirect "just" indentationWrapper) true)).success) "resolver fixture: matching indented contract must refuse its own evaluated wrapper (indentation guard is load-bearing)";
  assert lib.assertMsg (lib.all (line: builtins.elem line (programInvocations "just")) ["just --fmt --unstable" "${expectedJustExe} --fmt --unstable" "AGENT_TEST_ENV=1 just --fmt --unstable" "AGENT_TEST_ENV=1 ${expectedJustExe} --fmt --unstable"]) "resolver fixture: representatives must contain bare, exact, and environment-prefixed forms"; true;
  wrapper = script: {
    command = expectedBashExe;
    options = ["-euc" script "--"];
  };
  evilSameBasename = lib.replaceStrings [expectedJustExe] ["/tmp/evil/bin/just"] expectedJustScript;
  leadingBlank = "\n${expectedJustScript}";
  doubleSpace = lib.replaceStrings ["--fmt --unstable"] ["--fmt  --unstable"] expectedJustScript;
  reject = label: name: entry: {inherit label name entry;};
  negativeProbes = [
    (reject "evaluated-override-package" "just" overrideWrapper)
    (reject "evaluated-indented-script" "just" indentationWrapper)
    (reject "unknown-list-shell" "just" {command = ["/bin/bash" "-c" "echo hi"];})
    (reject "pinned-bash-unknown-script" "just" {
      command = expectedBashExe;
      options = ["-c" "echo hi"];
    })
    (reject "historical-bash" "just" {
      command = "/bin/bash";
      options = ["-euc" expectedJustScript "--"];
    })
    (reject "sh-substitution" "just" {
      command = "/bin/sh";
      options = ["-euc" expectedJustScript "--"];
    })
    (reject "dash-substitution" "just" {
      command = "/bin/dash";
      options = ["-euc" expectedJustScript "--"];
    })
    (reject "alternate-package-script" "just" (wrapper (mkJustScript "/nix/store/ffffffffffffffffffffffffffffffff-alt/bin/just" [])))
    (reject "built-indentation-script" "just" (wrapper indentationContract.expectedJustScript))
    (reject "same-basename-evil-exe" "just" (wrapper evilSameBasename))
    (reject "alternate-store-evil-exe" "just" (wrapper (lib.replaceStrings [expectedJustExe] ["/nix/store/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee-evil/bin/just"] expectedJustScript)))
    (reject "mutated-indentation-script" "just" (wrapper (lib.replaceStrings ["--justfile"] ["--indentation \"  \" --justfile"] expectedJustScript)))
    (reject "leading-blank-line" "just" (wrapper leadingBlank))
    (reject "trailing-blank-line" "just" (wrapper "${expectedJustScript}\n"))
    (reject "double-space" "just" (wrapper doubleSpace))
    (reject "non-just-shell" "other" (wrapper "echo hi"))
    (reject "historical-non-just-shell" "other" {
      command = "/bin/bash";
      options = ["-euc" "echo hi" "--"];
    })
    (reject "LF-options" "fixture-direct" {
      command = "/bin/alejandra";
      options = ["--check\n."];
    })
    (reject "CR-options" "fixture-direct" {
      command = "/bin/alejandra";
      options = ["--check\r."];
    })
    (reject "LS-options" "fixture-direct" {
      command = "/bin/alejandra";
      options = ["--check${builtins.fromJSON ''"\u2028"''}."];
    })
    (reject "PS-options" "fixture-direct" {
      command = "/bin/alejandra";
      options = ["--check${builtins.fromJSON ''"\u2029"''}."];
    })
    (reject "comment-only-lookalike" "just" (wrapper "# ${expectedJustExe} --fmt --unstable --justfile"))
    (reject "echo-only-lookalike" "just" (wrapper ''echo "${expectedJustExe} --fmt --unstable --justfile"''))
    (reject "additional-command" "just" (wrapper "${expectedJustScript}\necho hi\n"))
    (reject "changed-shell-flags" "just" {
      command = expectedBashExe;
      options = ["-ec" expectedJustScript "--"];
    })
    (reject "extra-wrapper-args" "just" {
      command = expectedBashExe;
      options = ["-euc" expectedJustScript "--" "extra"];
    })
    (reject "changed-just-flags" "just" (wrapper (lib.replaceStrings ["--unstable"] ["--stable"] expectedJustScript)))
    (reject "changed-justfile-flag" "just" (wrapper (lib.replaceStrings ["--justfile"] ["--otherfile"] expectedJustScript)))
    (reject "empty-list" "fixture-empty" {command = [];})
    (reject "empty-list-head" "fixture-empty" {command = [""];})
    (reject "empty-string" "fixture-empty" {command = "";})
    (reject "non-string-element" "fixture-badtype" {command = [123];})
    (reject "multiline-command" "fixture-multi" {command = "foo\nbar";})
  ];
  detailed = map (probe: probe // {inherit ((attempt probe.name probe.entry)) success;}) negativeProbes;
  negativeAssertions =
    builtins.deepSeq (map (probe:
      assert lib.assertMsg (!probe.success) "resolver fixture: ${probe.label} must be rejected"; true)
    detailed)
    true;
in {
  ok = baseAssertions && negativeAssertions;
  report = {
    bash = expectedBashExe;
    justExe = expectedJustExe;
    scriptSha256 = builtins.hashString "sha256" expectedJustScript;
    inherit direct just;
    justCommands = programInvocations "just";
    justBare = "just --fmt --unstable";
    justExact = "${expectedJustExe} --fmt --unstable";
    justEnvExact = "AGENT_TEST_ENV=1 ${expectedJustExe} --fmt --unstable";
    overriddenJustExe = overrideContract.expectedJustExe;
    overriddenScriptSha256 = builtins.hashString "sha256" overrideContract.expectedJustScript;
    overriddenJust = overrideResolved;
    indentedScriptSha256 = builtins.hashString "sha256" indentationContract.expectedJustScript;
    standaloneJust = standalone.config.settings.formatter.just;
    evaluatedOverrideJust = overrideWrapper;
    evaluatedIndentedJust = indentationWrapper;
    fixtureFileSha256 = builtins.hashString "sha256" (builtins.readFile ./formatter-policy-fixtures.nix);
    resolverFileSha256 = builtins.hashString "sha256" (builtins.readFile ./formatter-policy.nix);
    negativeDigest = builtins.hashString "sha256" (builtins.toJSON detailed);
    negativeCount = builtins.length detailed;
  };
}
