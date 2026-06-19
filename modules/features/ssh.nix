{
  config,
  lib,
  ...
}:
{
  # Host ssh-agent holds the SSH keys so sandboxed agents can sign commits
  # and auth to git remotes WITHOUT reading ~/.ssh — they reach the agent
  # over $SSH_AUTH_SOCK (inherited by nono) and only ask it to sign blobs.
  services.ssh-agent.enable = true;

  programs.ssh = {
    enable = true;
    enableDefaultConfig = false;
    matchBlocks = {
      "github.com" = {
        hostname = "github.com";
        user = "git";
        identityFile = "~/.ssh/id_personal.pub";
        identitiesOnly = true;
      };

      "*" = {
        identityFile = "~/.ssh/id_personal.pub";
        forwardAgent = false;
        compression = false;
        serverAliveInterval = 0;
        serverAliveCountMax = 3;
        hashKnownHosts = false;
        userKnownHostsFile = "~/.ssh/known_hosts";
        controlMaster = "no";
        controlPath = "~/.ssh/master-%r@%n:%p";
        controlPersist = "no";
      };
    };
  };

  programs.fish.shellInit = lib.mkMerge [
    # $XDG_RUNTIME_DIR is normally set by pam_systemd at login, but tailscale
    # SSH sessions don't run PAM, so it's absent — and HM's ssh-agent module
    # expands $XDG_RUNTIME_DIR when setting SSH_AUTH_SOCK. Set a fallback
    # before HM's init (mkOrder 900): mkBefore runs first, so HM sees a real
    # value rather than an empty string.
    (lib.mkBefore ''
      if test -z "$XDG_RUNTIME_DIR"
          set -x XDG_RUNTIME_DIR /run/user/(id -u)
      end
    '')

    # Pre-load keys at shell init so git commit signing works before any
    # interactive ssh auth. Idempotent via `ssh-add -l`; id_work is guarded by
    # `test -f` (only on the work machine). The `begin; ... end` group is
    # required: `A; or B; and C` in fish binds as `(A or B) and C`, which
    # would run C whenever A succeeds.
    (lib.mkAfter ''
      if set -q SSH_AUTH_SOCK; and test -S "$SSH_AUTH_SOCK"
          ssh-add -l >/dev/null 2>&1; or begin; test -f ~/.ssh/id_personal; and ssh-add ~/.ssh/id_personal 2>/dev/null; end
          test -f ~/.ssh/id_work; and ssh-add ~/.ssh/id_work 2>/dev/null
      end
    '')
  ];
}

