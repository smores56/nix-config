{ config, lib, ... }:
{
  config = lib.mkIf config.dotfiles.exposeSsh {
    nix.settings.trusted-users = [ "smores" ];
  };
}
