{ config, pkgs, ... }:
{
  programs.alacritty = {
    enable = true;
    settings = {
      terminal.shell = config.dotfiles.shellPath;
      window = {
        decorations = "Buttonless";
        option_as_alt = "Both";
        blur = true;
      };
    };
  };
}
