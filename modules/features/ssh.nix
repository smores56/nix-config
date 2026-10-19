{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (pkgs.stdenv.hostPlatform) isLinux;
  home = lib.replaceStrings [ "~" ] [ "$HOME" ];

  # ssh, git signing and allowed_signers read these .pub files, while the
  # private halves stay in the vault. Fetches only missing files and never
  # fails: activation runs it before bootstrap has logged pass-cli in, so a
  # failed fetch warns and bootstrap reruns it after login.
  sshPubKeys = pkgs.writeShellApplication {
    name = "ssh-pub-keys";
    text = ''
      # Appended, not prepended: an earlier pass-cli on PATH (the test's fake)
      # wins, and activation's bare PATH still finds this one.
      PATH=$PATH:${config.services.proton-pass-agent.package}/bin
      # Any other provider makes pass-cli force a logout and delete the
      # session; activation does not see the session variable.
      export PROTON_PASS_KEY_PROVIDER=fs

      fetch() {
        local title=$1 dest=$2 dir key tmp
        dir=$(dirname "$dest")
        [ -e "$dest" ] && return 0
        # A real key is one line; anything else (an error on stdout) is not
        # worth writing where ssh and git will trust it.
        if ! key=$(pass-cli item view --vault-name Identity --item-title "$title" --field public_key </dev/null) \
          || [[ $key != ssh-* || $key == *$'\n'* ]]; then
          echo "ssh-pub-keys: could not fetch '$title' from Proton Pass for $dest. Log in with" >&2
          echo "  PROTON_PASS_KEY_PROVIDER=fs pass-cli login --interactive" >&2
          echo "then run ssh-pub-keys." >&2
          return 0
        fi
        [ -d "$dir" ] || { mkdir -p "$dir" && chmod 700 "$dir"; }
        tmp=$(mktemp "$dest.XXXXXX")
        printf '%s\n' "$key" >"$tmp"
        chmod 644 "$tmp"
        mv "$tmp" "$dest"
        echo "ssh-pub-keys: wrote $dest from Proton Pass" >&2
      }

      fetch Personal "$HOME/.ssh/id_personal.pub"
      fetch Work "${home config.dotfiles.work.sshKey}.pub"
    '';
  };
in
{
  # The client lives with its config rather than in the shared package list.
  # The identities themselves come from Proton Pass over SSH_AUTH_SOCK
  # (modules/features/proton-pass.nix), so no private key is read from ~/.ssh.
  home.packages = [
    pkgs.openssh
    sshPubKeys
  ];

  # git.nix's sshAllowedSigners orders itself after this, so keys fetched here
  # reach allowed_signers in the same switch.
  home.activation.sshPubKeys = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    run ${lib.getExe sshPubKeys}
  '';

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
        # Reuse one transport per destination: a fresh cloudflared ProxyCommand
        # also re-resolves the Access token via pass-cli, ~1.7s per invocation.
        ControlMaster = "auto";
        ControlPath = "~/.ssh/master-%r@%n:%p";
        ControlPersist = "10m";
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
