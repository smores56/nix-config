{ config, ... }:
{
  programs.kitty = {
    enable = true;
    settings.shell = config.dotfiles.shellPath;
  };
}
