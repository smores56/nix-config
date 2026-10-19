{ config, lib, ... }:
let
  ports = import ../ports.nix;
  # The vault's shared personal identity (design D6). Servers only ever hold
  # the public half; clients get the private half over SSH_AUTH_SOCK.
  authorizedKeys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEu3DfhswY9f9hum/0OhAw2833CkZOP6wVKW5yJk6GpU sam@sammohr.dev"
  ];
in
{
  options.exposeSsh.enable = lib.mkEnableOption "sshd bound to loopback for Cloudflare Tunnel access";

  config = lib.mkIf config.exposeSsh.enable {
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
    nix.settings.trusted-users = [ config.machine.username ];
    # sshd authenticates against the vault's shared identity; the server only
    # ever holds the public half.
    users.users.${config.machine.username}.openssh.authorizedKeys.keys = authorizedKeys;
  };
}
