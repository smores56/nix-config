{ config, lib, ... }:
let
  ports = import ../ports.nix;
in
{
  config = lib.mkIf config.dotfiles.exposeSsh {
    services.openssh = {
      enable = true;
      # Reachable only through the Cloudflare Tunnel: cloudflared dials
      # 127.0.0.1:${toString ports.ssh}, so sshd binds loopback and opens no firewall port.
      openFirewall = false;
      listenAddresses = [
        {
          addr = "127.0.0.1";
          port = ports.ssh;
        }
      ];
      settings = {
        # Key-only: no passwords, no keyboard-interactive, no root login.
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
        PermitRootLogin = "no";
        PubkeyAuthentication = true;
        # Accept COLORTERM and TERM from client for truecolor support over SSH
        AcceptEnv = [
          "COLORTERM"
          "TERM"
        ];
      };
    };
    security.sudo.wheelNeedsPassword = false;
    nix.settings.trusted-users = [ config.dotfiles.username ];
    # sshd authenticates against the vault's shared identity; the server only
    # ever holds the public half (dotfiles.sshAuthorizedKeys).
    users.users.${config.dotfiles.username}.openssh.authorizedKeys.keys =
      config.dotfiles.sshAuthorizedKeys;
  };
}
