# Assert-based contract for lib.standaloneRoot: harbor root names, standalone.
{standaloneRoot}: let
  fake = name: {
    lib.marker = name;
    treefmtModules.fmt = name;
    templates.default = name;
    packages.x86_64-linux.tool = name;
  };
  root = standaloneRoot {
    core = fake "core";
    python = fake "python";
    projects = fake "projects";
    solana = fake "solana";
  };
in
  assert root.lib.core.marker == "core";
  assert root.lib.python.marker == "python";
  assert root.lib.docs.marker == "projects";
  assert root.lib.blockchain.solana.marker == "solana";
  assert !(root.lib ? projects) && !(root.lib ? solana);
  assert root.treefmtModules == {core-fmt = "core"; python-fmt = "python"; projects-fmt = "projects"; solana-fmt = "solana";};
  assert root.templates.python-default == "python";
  assert root.packages.x86_64-linux.solana-tool == "solana";
    true
