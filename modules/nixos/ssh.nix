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
  # The agent's key is forced into the agent VM on every host; the PIV login
  # keys keep normal interactive shells.
  agentVm = import ../lib/agent-vm.nix { inherit pkgs lib; };
  agentLoginShell = agentVm.agentLoginShell user;
  # After the cutover the forced command has no guest to land in; sshd keeps the
  # ordinary fish shell and the PIV keys only.
  cutover = config.kanbeiSplit.cutover.enable or false;
  forcedKey =
    k:
    ''command="${agentVm.agentSsh user}/bin/agent-ssh",no-user-rc,no-port-forwarding,no-agent-forwarding,no-X11-forwarding ${k.pubkey}'';
  # The personal sops signing key is also the laptop guest's login: forced
  # into this host's guest, never an interactive host shell.
  signingKeys = import ../lib/signing-keys.nix;
  authorizedKeys = map (k: k.pubkey) yubikeyKeys.piv ++ [
    (forcedKey { pubkey = signingKeys.personal; })
  ];
  authorizedKeysAtCutover = map (k: k.pubkey) yubikeyKeys.piv;
in
{
  options.exposeSsh.enable = lib.mkEnableOption "sshd bound to loopback for Cloudflare Tunnel access";
  options.sudoKey.enable = lib.mkEnableOption "YubiKey touch-only sudo via pam_rssh (without sshd)";
  options.sudoTicketTimeout = lib.mkOption {
    type = lib.types.ints.unsigned;
    default = 5;
    description = ''
      Minutes a successful sudo authentication stays valid; 0 asks for a fresh
      touch or password every time. A host that needs another value sets this
      option, because sudo keeps one `Defaults timestamp_timeout` per file and
      a second entry would leave the outcome to ordering.
    '';
  };

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
          # Key-first, still password-capable: the account password is the
          # break-glass login when no YubiKey is at hand. The tunnel's Access
          # policy and the loopback bind stay the outer gate, and
          # KbdInteractiveAuthentication stays off so only the PAM password path
          # remains; root never logs in.
          PasswordAuthentication = true;
          KbdInteractiveAuthentication = false;
          PermitRootLogin = "no";
          PubkeyAuthentication = true;
          # Left at sshd's `any` so either factor is accepted; `publickey` alone
          # would make the password fallback unreachable. A FIDO2 login key would
          # have to assert user verification (PIN); none is authorized, and this
          # has no effect on PIV and software keys.
          PubkeyAuthOptions = "verify-required";
          AllowUsers = [ user ];
          # sshfs (pm) uses the SFTP subsystem, not TCP forwarding. Only the
          # agent is forwarded, for pam_rssh; commits sign with the host's sops
          # key, so no socket or port is forwarded onto the server.
          AllowTcpForwarding = "no";
          AllowStreamLocalForwarding = "no";
          AllowAgentForwarding = "yes";
          # A per-key command= does NOT suppress ~/.ssh/rc; no-user-rc on the
          # forced key and this global setting both close it.
          PermitUserRC = false;
          # A rejected offer counts against the limit. Clients offer the three PIV keys, then the
          # password fallback, or the one forced sandbox key; headroom covers clients that also
          # offer agent keys.
          MaxAuthTries = 10;
          # A typed password follows the key offers, so the timer covers reaching
          # for the password manager, not just the auth round trips.
          LoginGraceTime = 60;
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
        shell = lib.mkForce (if cutover then pkgs.fish else agentLoginShell);
        openssh.authorizedKeys.keys = if cutover then authorizedKeysAtCutover else authorizedKeys;
      };
      # pam_shells/chsh read this; the shell also lands in systemPackages via
      # users-groups.nix, which creates /run/current-system/sw/bin/<name>.
      environment.shells = if cutover then [ pkgs.fish ] else [ agentLoginShell ];
    })

    # A server's ticket covers reaching for the password manager; the laptop
    # keeps sudo's own 5.
    (lib.mkIf config.exposeSsh.enable {
      sudoTicketTimeout = lib.mkDefault 15;
    })

    (lib.mkIf (config.exposeSsh.enable || config.sudoKey.enable) {
      # sudo must consult PAM for pam_rssh to run; the password remains the
      # fallback after the sufficient rssh module.
      security.sudo.wheelNeedsPassword = true;
      # One touch per TTY per 15 minutes on a server; a laptop keeps sudo's
      # default 5 so a hijacked session is not trusted for longer than before.
      # sudo records a successful (key or password) auth in its own timestamp,
      # so repeat sudos skip PAM entirely. host-hardening.nix sets
      # `sudoTicketTimeout = 0` here rather than adding a second Defaults line.
      security.sudo.extraConfig = "Defaults timestamp_timeout=${toString config.sudoTicketTimeout}";

      # Separate FIDO2 key (touch only, no PIN), never used for login, forwarded via the
      # client's sudo agent.
      environment.etc."ssh/sudo_authorized_keys".text = lib.concatMapStrings (
        k: "${k.pubkey}\n"
      ) yubikeyKeys.sudo;
      security.pam.rssh = {
        enable = true;
        settings = {
          auth_key_file = "/etc/ssh/sudo_authorized_keys";
        }
        // lib.optionalAttrs config.sudoKey.enable {
          # A laptop has no forwarded agent, so pam_rssh dials its local sudo
          # agent directly.
          ssh_agent_addr = "/run/user/${toString config.users.users.${user}.uid}/fido2-agent";
          # pam_rssh signs with each authorized handle in turn; without a cue
          # the touch wait looks like a hung sudo. The module's SIGINT patch
          # turns Ctrl-C during that wait into the password fallback below.
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
        {
          assertion =
            !config.exposeSsh.enable
            || cutover
            || (
              builtins.any (p: (p.name or "") == "agent-login-shell") config.environment.systemPackages
              && builtins.any (p: (p.name or "") == "agent-login-shell") config.environment.shells
            );
          message = "the forced-SSH login shell must be installed and listed in environment.shells";
        }
      ];
    }
  ];
}
