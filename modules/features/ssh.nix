{
  config,
  lib,
  ...
}:
let
  # The ssh-agent socket lives under a dedicated subdir of the runtime dir
  # ($XDG_RUNTIME_DIR on Linux, DARWIN_USER_TEMP_DIR on macOS) so the nono
  # sandbox can grant just that subdir (via `$XDG_RUNTIME_DIR/ssh-agent`, see
  # modules/features/ai/nono.nix) without exposing every other runtime socket
  # (dbus, pipewire, wayland, ...). The socket file is `<runtime>/ssh-agent/socket`.
  socketSuffix = "ssh-agent/socket";
in
{
  # A host ssh-agent holds the SSH keys so sandboxed agents (maki/pi/omp) can
  # authenticate to git remotes AND sign commits WITHOUT reading ~/.ssh — they
  # reach the agent over $SSH_AUTH_SOCK (inherited by nono by default) and only
  # ever ask it to sign a blob, never seeing the private key. See
  # modules/features/ai/nono.nix for the matching socket + public-key grants.
  services.ssh-agent = {
    enable = true;
    socket = socketSuffix;
  };

  programs.ssh = {
    enable = true;
    enableDefaultConfig = false;
    matchBlocks = {
      "github.com" = {
        hostname = "github.com";
        user = "git";
        # Point at the .pub so ssh resolves the key via the agent rather than
        # reading the private key file (which nono denies). The agent, started
        # by services.ssh-agent above and pre-loaded by the fish shellInit
        # below, holds the private key — ssh asks it to sign, never reads ~/.ssh.
        identityFile = "~/.ssh/id_personal.pub";
        identitiesOnly = true;
      };

      "*" = {
        identityFile = "~/.ssh/id_personal.pub";
        forwardAgent = false;
        # Auto-load id_personal into the agent on first interactive ssh use.
        # Belt-and-suspenders with the fish shellInit preload below: whichever
        # runs first loads the key into the shared agent.
        addKeysToAgent = "yes";
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

  # Pre-load the SSH keys into the agent at shell init so git commit signing
  # works even when no interactive ssh auth has happened yet this session.
  # Runs in the UNSANDBOXED fish shell (the `m`/`o`/`pi` abbrs launch nono
  # AFTER fish shellInit, so the key load happens pre-sandbox and the agent
  # holds the key before maki starts). Idempotent: ssh-add -l short-circuits
  # the `or` once any key is loaded. Each key guarded by `test -f` because
  # id_work only exists on the work machine. Not backgrounded: ssh-add is
  # ~10ms when the key is present, and backgrounding would race `git commit`.
  # The `begin; ... end` group is required: `A; or B; and C` in fish binds as
  # `(A or B) and C`, which would run C whenever A succeeds — the group makes
  # `or` own the whole file-check-and-load chain so a loaded key short-circuits.
  programs.fish.shellInit = lib.mkAfter ''
    if set -q SSH_AUTH_SOCK; and test -S "$SSH_AUTH_SOCK"
        ssh-add -l >/dev/null 2>&1; or begin; test -f ~/.ssh/id_personal; and ssh-add ~/.ssh/id_personal 2>/dev/null; end
        test -f ~/.ssh/id_work; and ssh-add ~/.ssh/id_work 2>/dev/null
    end
  '';
}

