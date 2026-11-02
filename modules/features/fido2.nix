# YubiKey session plumbing: one ssh-agent that holds the PIV login key and the
# touch-only sudo handles, and an askpass that feeds the PIV PIN from a
# per-session cache.
#
# The goal is "free" SSH after login: the PIV key needs only its PIN, cached
# once per session in $XDG_RUNTIME_DIR (tmpfs, 0600) instead of a keyring. Sudo
# uses a separate touch-required FIDO2 credential, so it costs one touch and no
# PIN. Commit signing does not touch the YubiKeys (sops keys, git.nix).
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
  fido2Pin = import ../lib/fido2-pin.nix { inherit pkgs; };
  inherit (fido2Pin) ensurePin;

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

  # ssh invokes this through SSH_ASKPASS_REQUIRE=force. It answers only the PIV
  # PIN prompt and never prompts on a tty: the agent has no tty, and a presence
  # request must be visible rather than silently answered. No FIDO2 credential
  # in use asks for a PIN (the sudo handles are touch-only), so a FIDO2 PIN
  # prompt fails closed. A cache miss opens the graphical prompt; when that is
  # impossible the failure stays loud and names the terminal fallback.
  askpass = pkgs.writeShellApplication {
    name = "ssh-pin-askpass";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.libnotify
    ];
    text = ''
      case "''${1:-}" in
        "Enter PIN for '"*) ;;
        "Confirm user presence for key"*)
          notify-send -u critical "YubiKey touch requested" "$1" || true
          exit 1
          ;;
        *) exit 1 ;;
      esac

      ${lib.getExe ensurePin} || exit 1
      cat "${pinFile}"
    '';
  };

  # yk-login is the recovery path: it prompts on the terminal through the
  # shared helper, restarts the agent so a reset OpenSC session cannot poison
  # it, and reloads the PIV provider and the three sudo handles. The PIV PIN
  # lives in ssh-pkcs11-helper memory once loaded; the cache file lets yk-ensure
  # reload it without a prompt.
  ykLogin = pkgs.writeShellApplication {
    name = "yk-login";
    runtimeInputs = [
      pkgs.openssh
      pkgs.opensc
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.systemd
    ];
    text = ''
      runtime="''${XDG_RUNTIME_DIR:?XDG_RUNTIME_DIR is not set}"

      if [ ! -t 0 ]; then
        echo "yk-login: run this in a terminal (needs a tty to hide input)" >&2
        exit 1
      fi

      # Prompt, verify, and cache in the shared helper: the retry guard and the
      # cache format are the same ones the agent askpass and yk-ensure rely on.
      ${lib.getExe ensurePin} --tty

      # Another PIV client (pam_p11, ykman, the old 9c fallback) resets OpenSC's
      # verified state. Restart the agent so a stale provider cannot fail with
      # "agent refused operation".
      systemctl --user restart fido2-agent.service
      for _ in $(seq 1 50); do
        [ -S "$runtime/fido2-agent" ] && break
        sleep 0.1
      done
      [ -S "$runtime/fido2-agent" ] || {
        echo "yk-login: the fido2 agent did not start" >&2
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

      echo "==> fido2-agent"
      SSH_AUTH_SOCK="$agent" ssh-add -l || true
    '';
  };

  # Loading a handle needs no PIN (it is useless without the physical key); a
  # sudo signature then costs one touch.
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

  agentEnv = [
    "SSH_ASKPASS=${lib.getExe askpass}"
    "SSH_ASKPASS_REQUIRE=force"
    "SSH_SK_HELPER=${lib.getExe skHelper}"
  ];

  # pam_p11 authorizes the PIV key by matching the token's certificate against
  # PEM certs in $HOME/.eid/authorized_certificates (it hardcodes that path).
  # Certificates are public, so they live in yubikey-keys.nix rather than a
  # vault. Rotating a PIV key means replacing its entry; an entry for a key that
  # is not plugged in is harmless. The NixOS side publishes the list at /etc/eid
  # and symlinks the home path at it, so the file root trusts at the greeter and
  # login cannot be swapped by a same-uid agent; see
  # modules/hosts/smorespro/greeter.nix.
  # Sudo handles are loaded at login only where a local agent is consumed; on
  # a server pam_rssh uses the forwarded one.
  isServer = builtins.elem "server" config.machine.profiles;
  yubikeyKeys = import ../lib/yubikey-keys.nix;
in
{
  config = lib.mkIf pkgs.stdenv.hostPlatform.isLinux {
    home.packages = [
      ykLogin
      askpass
      ensurePin
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

    # A dedicated agent rather than `services.ssh-agent`: the systemd user
    # session's sshAuthSock allows only one provider. `Host smortress` selects
    # this socket with IdentityAgent and forwards it for pam_rssh.
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
  };
}
