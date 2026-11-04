# The Linux laptop's sudo agent: touch-only FIDO2 handles, dialed by local
# pam_rssh and forwarded to smortress. Started without a provider allow-list,
# so it cannot hold the PIV login key (that lives in piv-agent, piv.nix).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  yubikeyKeys = import ../lib/yubikey-keys.nix;
  isServer = builtins.elem "server" config.machine.profiles;

  # OpenSSH's only libfido2 consumer is libexec/ssh-sk-helper. The default
  # libfido2 links PC/SC, so with pcscd running (PIV) it enumerates the same
  # YubiKey twice (USB HID + PC/SC) and OpenSSH asks for a touch just to pick
  # one. LD_LIBRARY_PATH swaps in a libfido2 without PC/SC, so no OpenSSH
  # package hash changes and the binary cache still supplies it.
  libfido2NoPcsc = pkgs.libfido2.override { withPcsclite = false; };
  skHelper = pkgs.writeShellApplication {
    name = "ssh-sk-helper-no-pcsc";
    text = ''
      export LD_LIBRARY_PATH="${libfido2NoPcsc}/lib"
      exec "${pkgs.openssh}/libexec/ssh-sk-helper" "$@"
    '';
  };

  # ssh uses this through SSH_ASKPASS_REQUIRE=force. Nothing it could be asked
  # needs an answer (piv-ensure owns the PIV PIN; the sudo handles are
  # touch-only), so a presence request is announced and every prompt fails
  # closed; a changed host key can never be accepted unseen.
  askpass = pkgs.writeShellApplication {
    name = "ssh-askpass";
    runtimeInputs = [ pkgs.libnotify ];
    text = ''
      case "''${1:-}" in
        "Confirm user presence for key"*)
          "''${SSH_ASKPASS_NOTIFY:-notify-send}" -u critical "YubiKey touch requested" "$1" || true
          ;;
      esac
      exit 1
    '';
  };

  # Loading a handle needs no PIN (it is useless without the physical key).
  loadHandles = pkgs.writeShellApplication {
    name = "fido2-agent-load";
    runtimeInputs = [ pkgs.openssh ];
    text = ''
      export SSH_AUTH_SOCK="$XDG_RUNTIME_DIR/fido2-agent"
      export SSH_SK_HELPER="${lib.getExe skHelper}"
      ${lib.concatMapStrings (k: ''
        if [ -f "$HOME/.config/ssh-sk/${k.key}" ]; then
          ssh-add "$HOME/.config/ssh-sk/${k.key}" >/dev/null 2>&1 || true
        fi
      '') yubikeyKeys.sudo}
    '';
  };
in
{
  config = lib.mkIf (pkgs.stdenv.hostPlatform.isLinux && !isServer) {
    home.packages = [ askpass ];

    home.sessionVariables = {
      SSH_ASKPASS = lib.getExe askpass;
      SSH_ASKPASS_REQUIRE = "force";
      SSH_SK_HELPER = lib.getExe skHelper;
    };

    systemd.user.services.fido2-agent = {
      Unit = {
        Description = "ssh-agent for the touch-only YubiKey sudo handles";
        StartLimitIntervalSec = 0;
      };
      Service = {
        Type = "simple";
        ExecStart = "${pkgs.openssh}/bin/ssh-agent -D -a %t/fido2-agent";
        Environment = [
          "SSH_ASKPASS=${lib.getExe askpass}"
          "SSH_ASKPASS_REQUIRE=force"
          "SSH_SK_HELPER=${lib.getExe skHelper}"
        ];
        Restart = "on-failure";
        RestartSec = 2;
      };
      Install.WantedBy = [ "default.target" ];
    };

    systemd.user.services.fido2-agent-load = {
      Unit = {
        Description = "Load the touch-only sudo handles into fido2-agent";
        After = [ "fido2-agent.service" ];
        Wants = [ "fido2-agent.service" ];
        PartOf = [ "fido2-agent.service" ];
      };
      Service = {
        Type = "oneshot";
        RemainAfterExit = true;
        # Type=simple: ssh-agent may not have created the socket yet.
        ExecStartPre = "${lib.getExe pkgs.bashNonInteractive} -c 'for ((i = 0; i < 300; i++)); do [ -S %t/fido2-agent ] && exit 0; sleep 0.1; done; exit 1'";
        ExecStart = lib.getExe loadHandles;
      };
      Install.WantedBy = [ "default.target" ];
    };
  };
}
