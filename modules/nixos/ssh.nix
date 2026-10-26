{ config, lib, ... }:
let
  ports = import ../ports.nix;
  user = config.machine.username;
  # Public halves of the login credentials. Private halves never touch a host:
  # the FIDO2 credentials live on the YubiKeys, the legacy software identity is
  # served by the Proton Pass agent until all three keys are enrolled.
  authorizedKeys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEu3DfhswY9f9hum/0OhAw2833CkZOP6wVKW5yJk6GpU sam@sammohr.dev"
    # k1 (touch + PIN) — personal and work identities.
    # no-touch-required: SSH is free after login (the PIN comes from the
    # session cache); presence is the laptop login, not this signature.
    "no-touch-required sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIDLiB81jggq+Oa2K+zUTeIQkWf/UsfgZt4vgezUtuPBAAAAABHNzaDo= smores personal k1"
    "no-touch-required sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIMmKpZP/35tlH3Z7vM/Tje53S6MvB4Qj6miakUyf/tHJAAAABHNzaDo= smores work k1"
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
      # Only the root-owned Nix-managed file; a writable ~/.ssh/authorized_keys
      # would bypass the server-side policy.
      authorizedKeysInHomedir = false;
      settings = {
        # Key-only: no passwords, no keyboard-interactive, no root login.
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
        PermitRootLogin = "no";
        PubkeyAuthentication = true;
        # One factor. FIDO2 keys must assert user verification (the PIN); the
        # option has no effect on non-FIDO2 keys, so the legacy identity keeps
        # working until it is retired.
        AuthenticationMethods = "publickey";
        PubkeyAuthOptions = "verify-required";
        AllowUsers = [ user ];
        # sshfs (pm) uses the SFTP subsystem, not TCP forwarding; the agent is
        # forwarded for pam_rssh and signing.
        AllowTcpForwarding = "no";
        AllowAgentForwarding = "yes";
        # Every credential the agent offers is tried until one matches, and a
        # rejected offer counts against this limit; with 3 keys x 2 identities
        # the default 6 is too small.
        MaxAuthTries = 10;
        LoginGraceTime = 20;
        # Accept COLORTERM and TERM from client for truecolor support over SSH
        AcceptEnv = [
          "COLORTERM"
          "TERM"
        ];
      };
    };
    # Stays false until pam_rssh is wired; then it must become true for sudo to
    # consult PAM at all.
    security.sudo.wheelNeedsPassword = false;
    # The server only ever holds public halves.
    users.users.${user}.openssh.authorizedKeys.keys = authorizedKeys;
  };
}
