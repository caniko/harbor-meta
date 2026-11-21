_: {
  # xmllint --format is the only SVG formatter treefmt-nix ships.
  programs.xmllint = {
    enable = true;
    includes = ["*.svg"];
  };
}
