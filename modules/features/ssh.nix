{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (pkgs.stdenv.hostPlatform) isLinux;

  # Every identity key present on this host, each added only when the agent
  # lacks its fingerprint: signing with a .pub IdentityFile needs the key in
  # the agent, and an agent that already holds one key may still miss the
  # other. Hosts without the work key just skip it.
  loadSshKeys = pkgs.writeShellApplication {
    name = "load-ssh-keys";
    runtimeInputs = [
      pkgs.openssh
      pkgs.coreutils
      pkgs.gnugrep
    ];
    text = ''
      loaded=$(ssh-add -l 2>/dev/null || true)
      for key in ~/.ssh/id_personal ${config.dotfiles.work.sshKey}; do
        [ -f "$key" ] || continue
        fp=$(ssh-keygen -lf "$key.pub" 2>/dev/null | cut -d' ' -f2 || true)
        if [ -z "$fp" ] || ! grep -qF -- " $fp " <<<"$loaded"; then
          ssh-add "$key" 2>/dev/null || true
        fi
      done
    '';
  };
in
{
  # The client lives with its config rather than in the shared package list.
  home.packages = [
    pkgs.openssh
    loadSshKeys
  ];

  # Host ssh-agent holds the SSH keys so tooling can sign commits and auth
  # to git remotes WITHOUT reading ~/.ssh — agents only ask the agent to
  # sign blobs (private keys are never on disk in agent contexts).
  services.ssh-agent.enable = true;

  # HM restarts ssh-agent on each activation, but `ssh-agent -D -a %t/ssh-agent`
  # leaves the socket file behind when killed, so the new instance fails with
  # "Address already in use" and stays failed. Remove the stale socket first.
  systemd.user.services.ssh-agent.Service.ExecStartPre = "-${pkgs.coreutils}/bin/rm -f %t/ssh-agent";

  programs.ssh = {
    enable = true;
    enableDefaultConfig = false;
    # HM renamed `matchBlocks` → `settings` (dagOf of freeform blocks keyed by
    # Host pattern). Directive names use upstream OpenSSH casing (HostName,
    # IdentityFile, …); booleans render as yes/no automatically.
    settings = {
      "github.com" = {
        HostName = "github.com";
        User = "git";
        IdentityFile = "~/.ssh/id_personal.pub";
        IdentitiesOnly = true;
      };

      "*" = {
        IdentityFile = "~/.ssh/id_personal.pub";
        ForwardAgent = false;
        Compression = false;
        ServerAliveInterval = 0;
        ServerAliveCountMax = 3;
        HashKnownHosts = false;
        UserKnownHostsFile = "~/.ssh/known_hosts";
        ControlMaster = "no";
        ControlPath = "~/.ssh/master-%r@%n:%p";
        ControlPersist = "no";
      };
    };
  };

  # Work-org git remotes use this instead of ~/.ssh/config (via the git work
  # include's core.sshCommand). Standalone on purpose: IdentityFile entries
  # accumulate across config blocks, so layering on the main config would
  # also offer id_personal and could authenticate as the personal account.
  home.file.${lib.removePrefix "~/" config.dotfiles.work.sshConfig}.text = ''
    Host github.com
      HostName github.com
      User git
      IdentityFile ${config.dotfiles.work.sshKey}.pub
      IdentitiesOnly yes
  '';

  # $XDG_RUNTIME_DIR is normally set by pam_systemd at login, but tailscale
  # SSH sessions don't run PAM, so it's absent — and HM's ssh-agent module
  # expands $XDG_RUNTIME_DIR when setting SSH_AUTH_SOCK. Set a fallback
  # before HM's init (fish mkBefore; zsh .zshenv). Linux only: darwin has no
  # /run, its agent socket comes from DARWIN_USER_TEMP_DIR, and a dangling
  # value breaks tools that put sockets there (`op` fails to start its
  # daemon). Keys are pre-loaded at shell init so git commit signing works
  # before any interactive ssh auth.
  programs.fish.shellInit = lib.mkMerge [
    (lib.mkIf isLinux (
      lib.mkBefore ''
        if test -z "$XDG_RUNTIME_DIR"
            set -x XDG_RUNTIME_DIR /run/user/(id -u)
        end
      ''
    ))
    (lib.mkAfter ''
      if set -q SSH_AUTH_SOCK; and test -S "$SSH_AUTH_SOCK"
          ${lib.getExe loadSshKeys}
      end
    '')
  ];

  programs.zsh = {
    envExtra = lib.mkIf isLinux ''
      : "''${XDG_RUNTIME_DIR:=/run/user/$(id -u)}"
      export XDG_RUNTIME_DIR
    '';
    initContent = lib.mkOrder 1400 ''
      if [[ -n ''${SSH_AUTH_SOCK-} && -S $SSH_AUTH_SOCK ]]; then
        ${lib.getExe loadSshKeys}
      fi
    '';
  };
}
