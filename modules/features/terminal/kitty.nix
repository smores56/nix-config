{ config, pkgs, ... }:
{
  programs.kitty = {
    package = pkgs.nil;
    enable = true;
    settings.shell = config.dotfiles.shellPath;
  };
}
