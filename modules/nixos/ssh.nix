{
  config,
  lib,
  pkgs,
  ...
}:
let
  ports = import ../ports.nix;
  # Public halves of the login credentials. Private halves never touch a host:
  # each PIV key lives in its YubiKey's slot 9a.
  yubikeyKeys = import ../lib/yubikey-keys.nix;
  user = config.machine.username;
  # The agent gets the no-touch signing credential only, and every host
  # forces its sessions into the sandbox. The PIV login keys keep normal
  # interactive shells.
  agentSandbox = import ../lib/agent-sandbox.nix {
    inherit pkgs lib;
    home = config.users.users.${user}.home;
    isServer = builtins.elem "server" config.machine.profiles;
    isDarwin = false;
  };
  forcedKey =
    k:
    ''command="${agentSandbox.agentSsh}/bin/agent-ssh",no-user-rc,no-port-forwarding,no-agent-forwarding,no-X11-forwarding ${k.pubkey}'';
  authorizedKeys = map (k: k.pubkey) yubikeyKeys.piv ++ map forcedKey yubikeyKeys.signing;
in
{
  options.exposeSsh.enable = lib.mkEnableOption "sshd bound to loopback for Cloudflare Tunnel access";
  options.sudoKey.enable = lib.mkEnableOption "YubiKey touch-only sudo via pam_rssh (without sshd)";

  config = lib.mkMerge [
    (lib.mkIf config.exposeSsh.enable {
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
          # A per-key command= does NOT suppress ~/.ssh/rc; no-user-rc on the
          # signing keys and this global setting both close it.
          PermitUserRC = false;
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
      # The server only ever holds public halves. The forced command is
      # executed by the login shell; the wrapper skips fish's user config for
      # exactly that command and runs fish normally everywhere else.
      users.users.${user} = {
        shell = lib.mkForce agentSandbox.agentLoginShell;
        openssh.authorizedKeys.keys = authorizedKeys;
      };
    })

    (lib.mkIf (config.exposeSsh.enable || config.sudoKey.enable) {
      # sudo must consult PAM for pam_rssh to run; the password remains the
      # fallback after the sufficient rssh module.
      security.sudo.wheelNeedsPassword = true;
      # One touch per TTY per 15 minutes on a server; a laptop keeps sudo's
      # default 5 so a hijacked session is not trusted for longer than before.
      # sudo records a successful (key or password) auth in its own timestamp,
      # so repeat sudos skip PAM entirely.
      security.sudo.extraConfig = "Defaults timestamp_timeout=${
        if config.exposeSsh.enable then "15" else "5"
      }";

      # The sudo credential is a separate FIDO2 key (touch only, no PIN), never
      # used for login. It is forwarded to the server through the client's
      # fido2-agent. All three keys are enrolled.
      environment.etc."ssh/sudo_authorized_keys".text = lib.concatMapStrings (
        k: "${k.pubkey}\n"
      ) yubikeyKeys.sudo;
      security.pam.rssh = {
        enable = true;
        settings = {
          auth_key_file = "/etc/ssh/sudo_authorized_keys";
        }
        // lib.optionalAttrs config.sudoKey.enable {
          # A laptop forwards no agent and its SSH_AUTH_SOCK belongs to the
          # Pass agent, so pam_rssh dials the local fido2-agent directly.
          ssh_agent_addr = "/run/user/${toString config.users.users.${user}.uid}/fido2-agent";
          # pam_rssh signs with each authorized handle in turn; without a cue
          # the touch wait looks like a hung sudo.
          cue = true;
        };
      };
      security.pam.services.sudo.rssh = true;
    })

    {
      assertions = [
        {
          assertion = !(config.exposeSsh.enable && config.sudoKey.enable);
          message = "sudoKey dials a local fido2-agent; exposeSsh relies on a forwarded one";
        }
        {
          assertion = !config.sudoKey.enable || config.users.users.${user}.uid != null;
          message = "sudoKey needs a pinned uid for the fido2-agent socket path";
        }
      ];
    }
  ];
}
