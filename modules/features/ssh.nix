{
  config,
  lib,
  ...
}:
{
  # Host ssh-agent holds the SSH keys so sandboxed agents can sign commits
  # and auth to git remotes WITHOUT reading ~/.ssh — smolvm's `ssh_agent`
  # Smolfile flag forwards the agent socket into the VM, and agents only
  # ask the agent to sign blobs (private keys never enter the guest).
  services.ssh-agent.enable = true;

  # HM restarts ssh-agent on each activation, but `ssh-agent -D -a %t/ssh-agent`
  # leaves the socket file behind when killed, so the new instance fails with
  # "Address already in use" and stays failed. Remove the stale socket first.
  systemd.user.services.ssh-agent.Service.ExecStartPre = "-rm -f %t/ssh-agent";

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
