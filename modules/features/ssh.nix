{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (pkgs.stdenv.hostPlatform) isLinux;
in
{
  # Logins use the PIV 9a keys (modules/features/fido2.nix); no private key is read from ~/.ssh.
  home.packages = [ pkgs.openssh ];

  programs.ssh = {
    enable = true;
    enableDefaultConfig = false;
    settings = {
      # GitHub is HTTPS + a PAT (modules/features/git.nix), so no SSH identity is offered. Commits sign
      # with the sops keys; the hardware keys only authenticate and authorize sudo.
      "github.com" = {
        HostName = "github.com";
        User = "git";
      };

      "*" = {
        Compression = false;
        ServerAliveInterval = 0;
        ServerAliveCountMax = 3;
        HashKnownHosts = false;
        UserKnownHostsFile = "~/.config/ssh/known_hosts";
      }
      // lib.optionalAttrs isLinux {
        # Reuse one transport per destination (a cloudflared ProxyCommand costs a tunnel handshake each
        # time), in the runtime dir, not ~/.ssh. darwin shares nothing: no XDG_RUNTIME_DIR (an unset
        # ${VAR} is a fatal config error) and its TMPDIR is too long for a socket path.
        ControlMaster = "auto";
        ControlPath = "\${XDG_RUNTIME_DIR}/ssh-%C";
        ControlPersist = "10m";
      };
    };
  };

  # Sessions that skip PAM leave $XDG_RUNTIME_DIR unset but the agent module expands it for
  # SSH_AUTH_SOCK: set a fallback first (fish mkBefore; zsh .zshenv). Linux only: darwin's agent
  # socket comes from DARWIN_USER_TEMP_DIR and a dangling value breaks `op`'s daemon.
  programs.fish.shellInit = lib.mkIf isLinux (
    lib.mkBefore ''
      if test -z "$XDG_RUNTIME_DIR"
          set -x XDG_RUNTIME_DIR /run/user/(id -u)
      end
    ''
  );

  programs.zsh.envExtra = lib.mkIf isLinux (
    lib.mkBefore ''
      : "''${XDG_RUNTIME_DIR:=/run/user/$(id -u)}"
      export XDG_RUNTIME_DIR
    ''
  );
}
