{ config, lib, ... }:
let
  ports = import ../ports.nix;
  user = config.machine.username;
  # Public halves of the login credentials. Private halves never touch a host:
  # each PIV key lives in its YubiKey's slot 9a.
  authorizedKeys = [
    # PIV slot 9a: PIN ONCE, touch NEVER. The PIN is unlocked once per login by
    # yk-login and the agent keeps the PIV session; all three keys are
    # interchangeable.
    "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBJ34zXLDQMZYvFX1q1fEMJ1/uGWvAtQUmu7/lzGqdWJBSAo2RPiYeeCZnA7AIhfwSwCIIv1sJWgopllQifFmZEc= smores piv k1"
    "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBMcpVmF/c9KcRgBlgRVp/gjrtjuB/+0U1nURKnep+dAt1NtUztpWtwlz7o3drWTHzydNaGZ39uO21TQ3rxMEOBA= smores piv k2"
    "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBOJHHVoKZWLnC1EVMVxFv9eNOtkZ+tJFI5TctBvOuzGAfYV0rlm6xv37RF2Pf+8DjUVEnwh9aGYwUsEFOoHUrPM= smores piv k3"
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
    # sudo must consult PAM for pam_rssh to run; the password remains the
    # fallback after the sufficient rssh module.
    security.sudo.wheelNeedsPassword = true;
    # One touch per TTY per 15 minutes: sudo records a successful (key or
    # password) auth in its own timestamp, so repeat sudos skip PAM entirely.
    security.sudo.extraConfig = "Defaults timestamp_timeout=15";

    # The sudo credential is a separate FIDO2 key (touch only, no PIN), never
    # used for login. It is forwarded to the server through the client's
    # fido2-agent. All three keys are enrolled.
    environment.etc."ssh/sudo_authorized_keys".text = ''
      sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIFtNyORYKzj2dpr3AnGla4hMyteHsn1uviR2cBNjrH1HAAAAC3NzaDpzdWRvLWsx smores sudo k1
      sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIHg8qZdcbsoYPfFCntYiqZkKbDOQucuWh1Y9ue8bW1AlAAAAC3NzaDpzdWRvLWsy smores sudo k2
      sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAILGL65a4LnBEjlj+tXGZiiU/94xcd9JPvgUcAaFDoRLbAAAAC3NzaDpzdWRvLWsz smores sudo k3
    '';
    security.pam.rssh = {
      enable = true;
      settings.auth_key_file = "/etc/ssh/sudo_authorized_keys";
    };
    security.pam.services.sudo.rssh = true;
    # The server only ever holds public halves.
    users.users.${user}.openssh.authorizedKeys.keys = authorizedKeys;
  };
}
