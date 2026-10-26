# FIDO2 session plumbing: an ssh-agent that holds the YubiKey credentials and
# an askpass that feeds it the PIN from a per-session cache.
#
# The goal is "free" SSH after login: with a no-touch-required + verify-required
# credential, the agent needs only the PIN, and the PIN is cached once per
# session in $XDG_RUNTIME_DIR (tmpfs, 0600) instead of a keyring. Sudo uses a
# separate touch-required credential, so it costs one touch and no PIN.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  # 0600, per login: XDG_RUNTIME_DIR is a tmpfs owned by the user and cleared at
  # logout. No keyring: a fingerprint/password login cannot unlock a
  # password-derived keyring, and niri never starts one.
  pinDir = "$XDG_RUNTIME_DIR/fido2";
  pinFile = "${pinDir}/pin";

  cachePin = pkgs.writeShellApplication {
    name = "fido2-pin-cache";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      if [ -s "${pinFile}" ]; then
        echo "fido2-pin-cache: PIN already cached for this session"
        exit 0
      fi
      if [ ! -t 0 ]; then
        echo "fido2-pin-cache: run this in a terminal (needs a tty to hide input)" >&2
        exit 1
      fi
      umask 077
      mkdir -p "${pinDir}"
      read -rsp 'FIDO2 PIN: ' pin
      echo
      if [ -z "$pin" ]; then
        echo "fido2-pin-cache: empty PIN, nothing cached" >&2
        exit 1
      fi
      printf '%s' "$pin" > "${pinFile}"
      chmod 600 "${pinFile}"
      unset pin
      echo "fido2-pin-cache: cached for this login session"
    '';
  };

  # ssh invokes this through SSH_ASKPASS_REQUIRE=force for the PKCS#11 PIN.
  # Lenient: the first use in a session prompts once on the tty and caches, so
  # an unlock that cannot supply the PIN (fingerprint/password) still works; a
  # PIV login will later populate it without prompting.
  askpass = pkgs.writeShellApplication {
    name = "ssh-pin-askpass";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      # ssh/ssh-agent pass the prompt as $1; a confirmation prompt is not a PIN.
      case "''${1:-}" in
        *PIN* | *pin*) ;;
        *) exit 1 ;;
      esac
      if [ -r "${pinFile}" ]; then
        cat "${pinFile}"
        exit 0
      fi
      if [ ! -r /dev/tty ]; then
        echo "ssh-pin-askpass: no cached PIN and no tty; run fido2-pin-cache" >&2
        exit 1
      fi
      umask 077
      mkdir -p "${pinDir}"
      read -rsp 'FIDO2/PIV PIN: ' pin < /dev/tty
      printf '\n' > /dev/tty
      if [ -z "$pin" ]; then
        exit 1
      fi
      printf '%s' "$pin" > "${pinFile}"
      chmod 600 "${pinFile}"
      printf '%s\n' "$pin"
      unset pin
    '';
  };

  # Loading a handle needs no PIN (it is useless without the physical key); the
  # PIN is requested per signature and answered by the askpass cache.
  loader =
    name: sockSuffix: keys:
    pkgs.writeShellApplication {
      name = name;
      runtimeInputs = [
        pkgs.openssh
        pkgs.coreutils
      ];
      text = ''
        export SSH_AUTH_SOCK="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/${sockSuffix}"
        ${lib.concatMapStrings (k: ''
          key="$HOME/${k}"
          if [ -f "$key" ]; then
            ssh-add "$key" >/dev/null 2>&1 || true
          fi
        '') keys}
      '';
    };

  # Personal/work are no-touch (SSH is free); sudo is touch-required, which is
  # the only gesture in daily use.
  loginKeys = [ ".config/ssh-sk/k1/sudo" ];
  signingKeys = [ ".config/ssh-sk/k1/signing" ];

  agentEnv = [
    "SSH_ASKPASS=${lib.getExe askpass}"
    "SSH_ASKPASS_REQUIRE=force"
  ];
in
{
  config = lib.mkIf pkgs.stdenv.hostPlatform.isLinux {
    home.packages = [
      cachePin
      askpass
      pkgs.opensc
    ];

    # The PKCS#11 / agent PIN prompt goes through this helper. `force` is
    # required because ssh prefers the tty otherwise; non-PIN prompts fail
    # closed (all hosts are key-only).
    home.sessionVariables.SSH_ASKPASS = lib.getExe askpass;
    home.sessionVariables.SSH_ASKPASS_REQUIRE = "force";

    # A dedicated agent rather than `services.ssh-agent`: the Proton Pass agent
    # still owns the global SSH_AUTH_SOCK (git/GitHub until that moves to HTTPS),
    # and sshAuthSock allows only one provider. `Host smortress` selects this
    # socket with IdentityAgent and forwards it for pam_rssh.
    systemd.user.services.fido2-agent = {
      Unit = {
        Description = "ssh-agent for the YubiKey login and sudo credentials";
        StartLimitIntervalSec = 0;
      };
      Service = {
        Type = "simple";
        ExecStart = "${pkgs.openssh}/bin/ssh-agent -D -a %t/fido2-agent";
        Environment = agentEnv;
        Restart = "on-failure";
        RestartSec = 2;
      };
      Install.WantedBy = [ "default.target" ];
    };

    systemd.user.services.fido2-agent-load = {
      Unit = {
        Description = "Load the YubiKey login credentials into fido2-agent";
        After = [ "fido2-agent.service" ];
        Requires = [ "fido2-agent.service" ];
        PartOf = [ "fido2-agent.service" ];
      };
      Service = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = lib.getExe (loader "fido2-agent-load" "fido2-agent" loginKeys);
      };
      Install.WantedBy = [ "default.target" ];
    };

    # Signing-only agent: the Maki sandbox will see this socket and nothing else.
    systemd.user.services.fido2-sign-agent = {
      Unit = {
        Description = "ssh-agent holding only the no-touch signing credential";
        StartLimitIntervalSec = 0;
      };
      Service = {
        Type = "simple";
        ExecStart = "${pkgs.openssh}/bin/ssh-agent -D -a %t/fido2-sign-agent";
        Environment = agentEnv;
        Restart = "on-failure";
        RestartSec = 2;
      };
      Install.WantedBy = [ "default.target" ];
    };

    systemd.user.services.fido2-sign-load = {
      Unit = {
        Description = "Load the signing credential into fido2-sign-agent";
        After = [ "fido2-sign-agent.service" ];
        Requires = [ "fido2-sign-agent.service" ];
        PartOf = [ "fido2-sign-agent.service" ];
      };
      Service = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = lib.getExe (loader "fido2-sign-load" "fido2-sign-agent" signingKeys);
      };
      Install.WantedBy = [ "default.target" ];
    };
  };
}
