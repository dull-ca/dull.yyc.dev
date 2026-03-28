{ pkgs, ... }:

{
  languages.javascript = {
    enable = true;
    bun = {
      enable = true;
      install.enable = true;
    };
  };

  packages = with pkgs; [
    biome
  ];
}
