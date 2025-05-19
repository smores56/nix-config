{ pkgs, ... }:
{
  programs.neovim = {
    enable = false;

    plugins = with pkgs.vimPlugins; [
      nvchad
    ];
  };
}
