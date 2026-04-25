{ config, lib, ... }:
{
  config = lib.mkIf (config.dotfiles.displayManager != null) {
    fonts.fontconfig.enable = true;
    home.sessionVariables.TERMINAL = config.dotfiles.terminal;
  };
}
