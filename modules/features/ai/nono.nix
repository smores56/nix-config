{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles.nono;

  # Shared launch pattern across every agent site (abbrs, herdr pane,
  # worktree spawns): callers invoke `nono run -s -- <cmd>` directly — no
  # wrapper, no `--allow-cwd` (the profile's workdir.access = "readwrite" below
  # already makes cwd writable from inside the sandbox), and no `-p agent`
  # flag (NONO_PROFILE is set in home.sessionVariables below). For
  # dangerous/unsubnetted edits, run `exec maki` directly (shorter than the
  # safe path, on purpose).

  # Single shared profile for maki/pi/omp. Extends nono's built-in `default`,
  # which denies ~/.ssh, ~/.aws, ~/.gnupg, ~/.kube, ~/.docker, keychains,
  # browser data, shell history/configs, and blocks dangerous_commands
  # (rm -rf, dd, sudo, kill, chmod, shred).
  #
  # ~/code is writable: a running nono session's capability set is
  # kernel-fixed at startup (no live-reload of profile JSON), and this profile
  # is a home.file symlink into the read-only Nix store, so a sandboxed
  # process can't widen the running session OR overwrite the next-run profile.
  agentProfile = {
    extends = "default";
    meta = {
      name = "agent";
      description = "Shared least-privilege profile for coding agents (maki/pi/omp): open network, filtered env, denied creds/sudo, gh token passthrough";
    };
    groups.include = [
      "nix_runtime"
      "node_runtime"
      "rust_runtime"
      "python_runtime"
      "go_runtime"
      "git_config"
      "user_tools"
    ];
    workdir.access = "readwrite";
    filesystem = {
      allow = [
        "$XDG_CACHE_HOME"
        "$HOME/.cargo"
        "$HOME/.npm"
        "$TMPDIR"
        "/tmp"
        # Agent state dirs (union across maki/pi/omp).
        "$XDG_CONFIG_HOME/maki"
        "$XDG_DATA_HOME/maki"
        "$XDG_STATE_HOME/maki"
        "$HOME/.local/logs/maki"
        "$HOME/.brv-cli"
        "$HOME/.pi"
        "$XDG_CONFIG_HOME/pi"
        "$XDG_DATA_HOME/pi"
        "$XDG_STATE_HOME/pi"
        "$HOME/.omp"
        "$XDG_DATA_HOME/oh-my-pi-cli"
        "$HOME/code"
        "$XDG_CONFIG_HOME/home-manager"
      ];
      read = [
        "$HOME/.bun"
        "$HOME/.wasmer"
        "$HOME/.wasmtime"
        # ssh-agent socket parent dir. ~/.ssh itself stays denied by
        # deny_credentials; only the .pub files below are bypassed.
        "$XDG_RUNTIME_DIR"
      ];
      # .pub + known_hosts for git ssh-format signing + host verification.
      # Private keys stay denied; signing goes through SSH_AUTH_SOCK.
      read_file = [
        "$HOME/.ssh/id_personal.pub"
        "$HOME/.ssh/id_work.pub"
        "$HOME/.ssh/known_hosts"
      ];
      bypass_protection = [
        "$HOME/.ssh/id_personal.pub"
        "$HOME/.ssh/id_work.pub"
        "$HOME/.ssh/known_hosts"
      ];
      # Defense in depth over default's deny_shell_configs. gh/hosts.yml
      # holds the OAuth token AND triggers maki's Copilot probe on launch;
      # denying it hides both. gh inside the sandbox authenticates via the
      # allowlisted GH_TOKEN env var instead (see environment.allow_vars),
      # so it never needs to read hosts.yml.
      deny = [
        "$XDG_CONFIG_HOME/fish/conf.d"
        "$XDG_CONFIG_HOME/gh"
      ];
    };
    # With network open, inherited shell secrets are both readable and
    # exfiltrable, so this allow-list is the primary secret control. nono's
    # non-overridable blocklist (LD_PRELOAD, DYLD_*, PYTHONPATH, NODE_OPTIONS)
    # is enforced regardless. Git push auth stays ssh-agent signing; gh runs
    # *inside* the sandbox via GH_TOKEN passthrough (see the gh-token.fish
    # snippet that exports GH_TOKEN from `gh auth token`). ~/.config/gh is
    # still denied below, so gh authenticates from GH_TOKEN alone with an
    # isolated GH_CONFIG_DIR — the on-disk OAuth token in hosts.yml is never
    # exposed. Token-theft-via-env is an accepted risk (operator watches
    # home-hosted agents running only reasonably-trusted code).
    environment.allow_vars = [
      "PATH"
      "HOME"
      "TERM"
      "LANG"
      "LC_ALL"
      "USER"
      "SHELL"
      "XDG_CONFIG_HOME"
      "XDG_DATA_HOME"
      "XDG_STATE_HOME"
      "XDG_CACHE_HOME"
      "XDG_RUNTIME_DIR"
      "TMPDIR"
      "SSH_AUTH_SOCK"
      # gh CLI passthrough: gh reads GH_TOKEN (preferred) or GITHUB_TOKEN.
      # Sourced from `gh auth token` in conf.d/gh-token.fish; real gho_ token
      # lives in env (exfiltrable) but hosts.yml stays denied.
      "GH_TOKEN"
      "GITHUB_TOKEN"
      # LLM/MCP provider keys read by maki/pi/omp (union across personal+work).
      "NEURALWATT_API_KEY"
      "XIAOMI_MIMO_API_KEY"
      "DEEPSEEK_API_KEY"
      "CLOUDFLARE_WORKERS_AI_API_TOKEN"
      "CLOUDFLARE_ACCOUNT_ID"
      "GLEAN_SERVER_URL"
      "GLEAN_API_TOKEN"
      "SLACK_MCP_XOXC_TOKEN"
      "SLACK_MCP_XOXD_TOKEN"
    ];
  };

  profileFiles = {
    ".config/nono/profiles/agent.json" = {
      force = true;
      text = builtins.toJSON agentProfile;
    };
  };

  # Sourced by fish into the host shell env so the `m`/`o`/`pi`/herdr abbrs
  # (which call `nono run -s -- <agent>`) inherit GH_TOKEN; the agent profile
  # allowlists it for passthrough into the sandbox (gh inside the sandbox
  # authenticates from this env var, never from ~/.config/gh/hosts.yml, which
  # stays denied). `command -v gh` + the login check guard against breaking a
  # shell on hosts without gh or before `gh auth login`. Export via
  # GITHUB_TOKEN too, since some tooling checks that name first.
  ghTokenFish = pkgs.writeText "gh-token.fish" ''
    if command -v gh >/dev/null 2>&1
        and gh auth status >/dev/null 2>&1
        set -gx GH_TOKEN (gh auth token)
        set -gx GITHUB_TOKEN $GH_TOKEN
    end
  '';
in
{
  options.dotfiles.nono = {
    enable =
      lib.mkEnableOption "nono sandbox for coding agents (maki/pi/omp) with open networking and env-var filtering"
      // {
        default = true;
      };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ pkgs.nono ];
    home.file = profileFiles // {
      ".config/fish/conf.d/gh-token.fish".source = ghTokenFish;
    };
    # NONO_PROFILE selects the `agent` profile so per-call `-p agent` flags
    # aren't needed. This is read by the nono binary from its launching shell's
    # environment *before* the sandbox is applied; it isn't an agent env var, so
    # it doesn't appear in agentProfile.environment.allow_vars.
    home.sessionVariables.NONO_PROFILE = "agent";
  };
}
