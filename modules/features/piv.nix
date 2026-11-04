# YubiKey SSH on the laptops: the PIV agent (slot 9a login key, never
# forwarded), the forwarded sudo agent (fido2.nix on Linux, launchd here on
# macOS), and the hosts that log in with PIV. piv-ensure warms the PIV agent
# before each connection, so the PIN is typed once per login session.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (pkgs.stdenv.hostPlatform) isLinux;
  home = config.home.homeDirectory;
  isServer = builtins.elem "server" config.machine.profiles;
  piv = import ../lib/piv.nix { inherit config lib pkgs; };
  yubikeyKeys = import ../lib/yubikey-keys.nix;

  identity = {
    IdentityAgent = piv.sock.ssh;
    IdentitiesOnly = "yes";
    IdentityFile = map (k: "~/.config/ssh-sk/${k.key}.pub") yubikeyKeys.piv;
  };
  sudoSock = if isLinux then "\${XDG_RUNTIME_DIR}/fido2-agent" else "${home}/.ssh/sudo-agent.sock";

  macPivAgent = pkgs.writeShellApplication {
    name = "piv-agent";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.openssh
    ];
    text = ''
      install -d -m 700 "$(dirname "${piv.sock.sh}")"
      rm -f "${piv.sock.sh}"
      exec ssh-agent -D -P "${piv.opensc}" -a "${piv.sock.sh}"
    '';
  };

  # Loading a handle needs no PIN; launchd restarts the agent and this reloads.
  macSudoAgent = pkgs.writeShellApplication {
    name = "sudo-agent";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.openssh
    ];
    text = ''
      sock="${sudoSock}"
      install -d -m 700 "$(dirname "$sock")"
      rm -f "$sock"
      ssh-agent -D -a "$sock" &
      agent=$!
      trap 'kill "$agent" 2>/dev/null || true' EXIT
      for _ in $(seq 1 50); do
        [ -S "$sock" ] && break
        sleep 0.1
      done
      for key in "$HOME"/.config/ssh-sk/k*/sudo; do
        [ -f "$key" ] || continue
        SSH_AUTH_SOCK="$sock" ssh-add "$key" >/dev/null || echo "sudo-agent: could not load $key" >&2
      done
      wait "$agent"
    '';
  };

  launchAgent = program: {
    enable = true;
    config = {
      ProgramArguments = [ (lib.getExe program) ];
      EnvironmentVariables.HOME = home;
      ThrottleInterval = 5;
      RunAtLoad = true;
      KeepAlive = true;
      StandardErrorPath = "${home}/Library/Logs/${program.name}.err";
    };
  };
in
lib.mkIf (!isServer) {
  programs.ssh.settings = {
    smortress = identity // {
      ForwardAgent = sudoSock;
    };
    # LAN-only, no tunnel; the same 9a identity as smortress.
    "tang-pi" = identity // {
      HostName = "10.0.0.193";
      User = "smores";
      ProxyCommand = "${lib.getExe piv.ensureProxy} ${pkgs.netcat}/bin/nc %h %p";
    };
  };

  systemd.user.services.piv-agent = lib.mkIf isLinux {
    Unit = {
      Description = "ssh-agent for the YubiKey PIV login key";
      StartLimitIntervalSec = 0;
    };
    Service = {
      Type = "simple";
      # OpenSSH refuses ssh-add -s providers outside the allow-list.
      ExecStart = "${pkgs.openssh}/bin/ssh-agent -D -P ${piv.opensc} -a %t/piv-agent";
      Restart = "on-failure";
      RestartSec = 2;
    };
    Install.WantedBy = [ "default.target" ];
  };

  launchd.agents = lib.mkIf (!isLinux) {
    piv-agent = launchAgent macPivAgent;
    sudo-agent = launchAgent macSudoAgent;
    piv-pin-wipe = {
      enable = true;
      config = {
        ProgramArguments = [
          "/bin/sh"
          "-c"
          ''rm -rf "$(/usr/bin/getconf DARWIN_USER_TEMP_DIR)piv"''
        ];
        RunAtLoad = true;
      };
    };
  };
}
