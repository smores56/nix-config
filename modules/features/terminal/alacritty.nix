{ config, pkgs, ... }:
{
  programs.alacritty = {
    package = pkgs.nil;
    enable = true;
    settings = {
      terminal.shell = "${pkgs.${config.dotfiles.shell}}/bin/${config.dotfiles.shell}";
      window = {
        decorations = "Buttonless";
        option_as_alt = "Both";
        blur = true;
      };
    };
  };
}
