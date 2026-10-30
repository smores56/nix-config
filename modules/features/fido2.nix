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

  # OpenSSH's only libfido2 consumer is libexec/ssh-sk-helper. The default
  # libfido2 links PC/SC, so with pcscd running (PIV) it enumerates the same
  # YubiKey twice (USB HID + PC/SC) and OpenSSH asks for a touch just to pick
  # one. Point the helper at a libfido2 built without PC/SC via LD_LIBRARY_PATH:
  # OpenSC/pam_p11 still talk to pcscd directly for PIV, and no OpenSSH package
  # hash changes, so the binary cache still supplies it.
  libfido2NoPcsc = pkgs.libfido2.override { withPcsclite = false; };
  skHelper = pkgs.writeShellApplication {
    name = "ssh-sk-helper-no-pcsc";
    text = ''
      # Replace any inherited LD_LIBRARY_PATH: the helper's RUNPATH supplies
      # its other dependencies, and only libfido2 must come from here.
      export LD_LIBRARY_PATH="${libfido2NoPcsc}/lib"
      exec "${pkgs.openssh}/libexec/ssh-sk-helper" "$@"
    '';
  };

  pinAskpass = pkgs.writeShellScriptBin "yk-login-pin-askpass" ''
    exec ${pkgs.coreutils}/bin/cat "''${XDG_RUNTIME_DIR:?}/fido2/pin"
  '';

  # ssh invokes this through SSH_ASKPASS_REQUIRE=force. It answers only the
  # two real PIN prompts and never prompts on a tty: the agent has no tty, and
  # a presence request must be visible rather than silently answered.
  askpass = pkgs.writeShellApplication {
    name = "ssh-pin-askpass";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.libnotify
    ];
    text = ''
      case "''${1:-}" in
        "Enter PIN for '"*) ;;
        "Enter PIN"*" key "*) ;;
        "Confirm user presence for key"*)
          notify-send -u critical "YubiKey touch requested" "$1" || true
          exit 1
          ;;
        *) exit 1 ;;
      esac

      if [ -r "${pinFile}" ]; then
        cat "${pinFile}"
        exit 0
      fi

      echo "ssh-pin-askpass: no cached PIN; run yk-login" >&2
      exit 1
    '';
  };

  # yk-login is the only place the PIN is read. It verifies the PIN against
  # the FIDO2 applet before caching it (so a typo cannot be replayed), refuses
  # below four retries, then loads the PIV provider and the three sudo/signing
  # handles into their agents. The PIV PIN lives in ssh-pkcs11-helper memory;
  # the cache file remains only for the FIDO2 signing credential.
  ykLogin = pkgs.writeShellApplication {
    name = "yk-login";
    runtimeInputs = [
      pkgs.yubikey-manager
      pkgs.openssh
      pkgs.opensc
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.gnused
      pkgs.systemd
    ];
    text = ''
      runtime="''${XDG_RUNTIME_DIR:?XDG_RUNTIME_DIR is not set}"
      pin_dir="$runtime/fido2"
      pin_file="$pin_dir/pin"

      if [ ! -t 0 ]; then
        echo "yk-login: run this in a terminal (needs a tty to hide input)" >&2
        exit 1
      fi

      read -rsp 'YubiKey PIN: ' pin
      echo
      [[ $pin =~ ^[0-9]{8}$ ]] || {
        echo "yk-login: PIN must be exactly 8 digits" >&2
        exit 1
      }

      info=$(ykman fido info 2>&1) || {
        echo "yk-login: could not read FIDO2 info" >&2
        exit 1
      }
      attempts=$(printf '%s\n' "$info" | sed -n 's/^PIN:[[:space:]]*\([0-9][0-9]*\) attempt(s) remaining.*/\1/p')
      if [ -z "$attempts" ]; then
        echo "yk-login: FIDO2 PIN is not set (or retries are unavailable)" >&2
        exit 1
      fi
      if [ "$attempts" -lt 4 ]; then
        echo "yk-login: only $attempts FIDO2 retries remain; refusing to send the PIN" >&2
        exit 1
      fi

      if ! ykman fido access verify-pin --pin "$pin" >/dev/null 2>&1; then
        echo "yk-login: PIN rejected; $(ykman fido info 2>/dev/null | sed -n 's/^PIN:[[:space:]]*/PIN: /p')" >&2
        exit 1
      fi

      umask 077
      mkdir -p "$pin_dir"
      printf '%s' "$pin" >"$pin_file"
      chmod 600 "$pin_file"
      unset pin

      # Another PIV client (pam_p11, ykman, the old 9c fallback) resets OpenSC's
      # verified state. Start fresh agents so a stale provider cannot fail with
      # "agent refused operation"; the cache above is already verified.
      systemctl --user restart fido2-agent.service fido2-sign-agent.service
      for _ in $(seq 1 50); do
        [ -S "$runtime/fido2-agent" ] && [ -S "$runtime/fido2-sign-agent" ] && break
        sleep 0.1
      done
      [ -S "$runtime/fido2-agent" ] && [ -S "$runtime/fido2-sign-agent" ] || {
        echo "yk-login: the fido2 agents did not start" >&2
        exit 1
      }

      agent="$runtime/fido2-agent"
      if ! SSH_AUTH_SOCK="$agent" ssh-add -l 2>/dev/null | grep -q 'PIV AUTH pubkey'; then
        SSH_AUTH_SOCK="$agent" \
          SSH_ASKPASS="${lib.getExe pinAskpass}" \
          SSH_ASKPASS_REQUIRE=force \
          ssh-add -s "${pkgs.opensc}/lib/opensc-pkcs11.so"
      fi

      ${lib.getExe (loader "fido2-agent-load" "fido2-agent" loginKeys)}
      ${lib.getExe (loader "fido2-sign-load" "fido2-sign-agent" signingKeys)}

      for sock in fido2-agent fido2-sign-agent; do
        echo "==> $sock"
        SSH_AUTH_SOCK="$runtime/$sock" ssh-add -l || true
      done
    '';
  };

  # Loading a handle needs no PIN (it is useless without the physical key); the
  # PIN is requested per signature and answered by the askpass cache.
  loader =
    name: sockSuffix: keys:
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = [
        pkgs.openssh
        pkgs.coreutils
      ];
      text = ''
        export SSH_AUTH_SOCK="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/${sockSuffix}"
        # yk-login invokes this loader directly, so do not rely on the caller
        # having the agent service's environment.
        export SSH_SK_HELPER="${lib.getExe skHelper}"
        ${lib.concatMapStrings (k: ''
          key="$HOME/${k}"
          if [ -f "$key" ]; then
            ssh-add "$key" >/dev/null 2>&1 || true
          fi
        '') keys}
      '';
    };

  # All three keys are interchangeable; load every handle that exists.
  loginKeys = map (k: ".config/ssh-sk/${k.key}") yubikeyKeys.sudo;
  signingKeys = map (k: ".config/ssh-sk/${k.key}") yubikeyKeys.signing;

  agentEnv = [
    "SSH_ASKPASS=${lib.getExe askpass}"
    "SSH_ASKPASS_REQUIRE=force"
    "SSH_SK_HELPER=${lib.getExe skHelper}"
  ];

  # pam_p11 authorizes the PIV key by matching the token's certificate against
  # PEM certs in ~/.eid/authorized_certificates. Certificates are public, so
  # they live in yubikey-keys.nix rather than a vault. Rotating a PIV key means
  # replacing its entry; an entry for a key that is not plugged in is harmless.
  # Sudo handles are loaded at login only where a local agent is consumed; on
  # a server pam_rssh uses the forwarded one.
  isServer = builtins.elem "server" config.machine.profiles;
  yubikeyKeys = import ../lib/yubikey-keys.nix;
  pivCerts = map (k: k.cert) yubikeyKeys.piv;
in
{
  config = lib.mkIf pkgs.stdenv.hostPlatform.isLinux {
    home.packages = [
      ykLogin
      askpass
      pkgs.opensc
    ];

    # The PKCS#11 / agent PIN prompt goes through this helper. `force` is
    # required because ssh prefers the tty otherwise; non-PIN prompts fail
    # closed (all hosts are key-only).
    home.sessionVariables.SSH_ASKPASS = lib.getExe askpass;
    home.sessionVariables.SSH_ASKPASS_REQUIRE = "force";
    # ssh/ssh-add/ssh-keygen launch ssh-sk-helper for HID operations; use the
    # no-PC/SC libfido2 so a running pcscd does not duplicate the YubiKey.
    home.sessionVariables.SSH_SK_HELPER = lib.getExe skHelper;

    # The greeter's pam_p11 reads this through root, so a store symlink is fine.
    # A locked PIV PIN makes pam_p11 report AUTHINFO_UNAVAIL, which the stack
    # treats as "step aside": the password still unlocks without removing the
    # key (see modules/hosts/smorespro/greeter.nix).
    home.file.".eid/authorized_certificates".text = lib.concatStringsSep "\n" pivCerts;

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
        # OpenSSH 10.4 refuses ssh-add -s providers that are not in the
        # agent's allow-list. Permit only the OpenSC PKCS#11 module.
        ExecStart = "${pkgs.openssh}/bin/ssh-agent -D -P ${pkgs.opensc}/lib/opensc-pkcs11.so -a %t/fido2-agent";
        Environment = agentEnv;
        Restart = "on-failure";
        RestartSec = 2;
      };
      Install.WantedBy = [ "default.target" ];
    };

    # The sudo handles need no PIN, so load them at login. A laptop has no
    # forwarded agent: without this, local pam_rssh sees an empty agent and
    # sudo falls back to the password until yk-login runs.
    systemd.user.services.fido2-agent-load = lib.mkIf (!isServer) {
      Unit = {
        Description = "Load the touch-only sudo handles into fido2-agent";
        After = [ "fido2-agent.service" ];
        Wants = [ "fido2-agent.service" ];
        # A restart (yk-login) clears the agent; re-run the load with it.
        PartOf = [ "fido2-agent.service" ];
      };
      Service = {
        Type = "oneshot";
        RemainAfterExit = true;
        # Type=simple: ssh-agent may not have created the socket yet.
        ExecStartPre = "${lib.getExe pkgs.bashNonInteractive} -c 'for ((i = 0; i < 300; i++)); do [ -S %t/fido2-agent ] && exit 0; sleep 0.1; done; exit 1'";
        ExecStart = "${lib.getExe (loader "fido2-agent-load" "fido2-agent" loginKeys)}";
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
  };
}
