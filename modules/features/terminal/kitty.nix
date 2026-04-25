{ config, pkgs, ... }:
{
  programs.kitty = {
    package = pkgs.nil;
    enable = true;
    settings.shell = "${pkgs.${config.dotfiles.shell}}/bin/${config.dotfiles.shell}";
  };
}
