{ config, lib, ... }:
{
  config = lib.mkIf config.dotfiles.exposeSsh {
    services.openssh.enable = true;
    security.sudo.wheelNeedsPassword = false;
    nix.settings.trusted-users = [ config.dotfiles.username ];

    # Accept COLORTERM and TERM from client for truecolor support over SSH
    services.openssh.extraConfig = ''
      AcceptEnv COLORTERM TERM
    '';
  };
}
