{ config, lib, ... }:
{
  config = lib.mkIf config.dotfiles.exposeSsh {
    services.openssh.enable = true;
    security.sudo.wheelNeedsPassword = false;
    nix.settings.trusted-users = [ config.dotfiles.username ];
  };
}
