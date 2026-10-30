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
  # The client lives with its config rather than in the shared package list.
  # The identities themselves come from Proton Pass over SSH_AUTH_SOCK
  # (modules/features/proton-pass.nix), so no private key is read from ~/.ssh.
  home.packages = [ pkgs.openssh ];

  programs.ssh = {
    enable = true;
    enableDefaultConfig = false;
    # HM renamed `matchBlocks` → `settings` (dagOf of freeform blocks keyed by
    # Host pattern). Directive names use upstream OpenSSH casing (HostName,
    # IdentityFile, …); booleans render as yes/no automatically.
    settings = {
      # GitHub is HTTPS + a fine-grained PAT (modules/features/git.nix); no SSH
      # identity is offered, because the hardware keys are registered as
      # signing keys only and the personal software key is retired.
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
        # Reuse one transport per destination: a fresh cloudflared ProxyCommand
        # also re-resolves the Access token via pass-cli, ~1.7s per invocation.
        # The socket lives in the per-user runtime dir, not ~/.ssh (the design
        # forbids private-key-adjacent state there). darwin shares nothing: it
        # has no XDG_RUNTIME_DIR (an unset ${VAR} is a fatal config error), and
        # its TMPDIR is too long for a socket path.
        ControlMaster = "auto";
        ControlPath = "\${XDG_RUNTIME_DIR}/ssh-%C";
        ControlPersist = "10m";
      };
    };
  };

  # Work-org git remotes use this instead of ~/.ssh/config (via the git work
  # include's core.sshCommand). Standalone on purpose: IdentityFile entries
  # accumulate across config blocks, so layering on the main config would
  # also offer id_personal and could authenticate as the personal account.
  home.file.${lib.removePrefix "~/" config.user.work.sshConfig}.text = ''
    Host github.com
      HostName github.com
      User git
      IdentityFile ${config.user.work.sshKey}.pub
      IdentitiesOnly yes
  '';

  # $XDG_RUNTIME_DIR is normally set by pam_systemd at login, but a session that
  # does not go through PAM leaves it unset — and the agent module expands
  # $XDG_RUNTIME_DIR when setting SSH_AUTH_SOCK. Set a fallback before that init
  # (fish mkBefore; zsh .zshenv). Linux only: darwin has no /run, its agent
  # socket comes from DARWIN_USER_TEMP_DIR, and a dangling value breaks tools
  # that put sockets there (`op` fails to start its daemon).
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
