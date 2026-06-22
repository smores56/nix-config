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
      description = "Shared least-privilege profile for coding agents (maki/pi/omp): open network, filtered env, denied creds/sudo, gh token injected per-session via NONO_ENV_FILE";
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
      # Defense in depth over default's deny_shell_configs. ~/.config/gh
      # (hosts.yml) holds the OAuth token AND triggers maki's Copilot probe
      # on every launch; denying it hides both. gh inside the sandbox can't
      # read hosts.yml, so the before hook injects GH_TOKEN + an isolated
      # GH_CONFIG_DIR via NONO_ENV_FILE (see session_hooks below).
      deny = [
        "$XDG_CONFIG_HOME/fish/conf.d"
        "$XDG_CONFIG_HOME/gh"
      ];
    };
    # With network open, inherited shell secrets are both readable and
    # exfiltrable, so this allow-list is the primary secret control. nono's
    # non-overridable blocklist (LD_PRELOAD, DYLD_*, PYTHONPATH, NODE_OPTIONS)
    # is enforced regardless. Critically, GH_TOKEN and GH_CONFIG_DIR are NOT
    # listed here: they are never in the host shell env (no fish exporter) and
    # reach the sandboxed child only via session_hooks.before + NONO_ENV_FILE,
    # which bypasses this filter. Git push auth stays ssh-agent signing.
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
    # Per-session setup/teardown that runs OUTSIDE the sandbox with host
    # privileges. The before hook reads the gh OAuth token from the (denied
    # inside-sandbox) hosts.yml and injects GH_TOKEN + an isolated
    # GH_CONFIG_DIR into the child env via NONO_ENV_FILE; the after hook
    # cleans up the per-session GH_CONFIG_DIR. Scripts live in the read-only
    # nix store (same trust model as this profile), so a sandboxed process
    # can't tamper with the next run's hooks.
    session_hooks = {
      before = { script = "${ghBeforeHook}"; timeout_secs = 10; };
      after = { script = "${ghAfterHook}"; timeout_secs = 10; };
    };
  };

  profileFiles = {
    ".config/nono/profiles/agent.json" = {
      force = true;
      text = builtins.toJSON agentProfile;
    };
  };

  # gh token + isolated GH_CONFIG_DIR are injected per-session via
  # session_hooks.before (below), NOT exported into the host shell env.
  # Why: ~/.config/gh is denied inside the sandbox (defense in depth on
  # top of deny_shell_configs, plus it silences maki's Copilot probe on
  # every launch). gh inside the sandbox therefore can't read hosts.yml.
  # The `before` hook runs OUTSIDE the sandbox with host privileges, reads
  # the OAuth token via `gh auth token`, and writes `GH_TOKEN=<token>` into
  # $NONO_ENV_FILE. nono applies NONO_ENV_FILE entries to the child AFTER the
  # environment.allow_vars filter, so they bypass it — verified empirically
  # (a var injected via NONO_ENV_FILE reaches the child even with
  # allow_vars=[]). This means:
  #   - GH_TOKEN/GITHUB_TOKEN are NEVER in the host shell env (no
  #     /proc/<shell>/environ leakage, no inheritance by non-agent children).
  #   - GH_TOKEN reaches the sandboxed agent for this session only, then is
  #     gone (the child env dies with the session).
  #   - GH_CONFIG_DIR points at a per-session empty writable dir under
  #     $XDG_CACHE_HOME (already in filesystem.allow), so gh never touches the
  #     denied ~/.config/gh. The `after` hook rm -rf's it on exit.
  # Token-theft-via-env while the session is live is an accepted risk
  # (operator watches home-hosted agents running only reasonably-trusted code).
  ghBeforeHook = pkgs.writeShellScript "nono-agent-before" ''
    # Reads the gh OAuth token host-side and injects GH_TOKEN + an isolated
    # GH_CONFIG_DIR into the sandboxed child's env via NONO_ENV_FILE. Runs
    # outside the sandbox (host privileges); everything written to
    # NONO_ENV_FILE as KEY=VALUE becomes child env, bypassing allow_vars.
    if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
      tok=$(gh auth token 2>/dev/null) || tok=""
      if [ -n "$tok" ]; then
        printf 'GH_TOKEN=%s\n' "$tok" >> "$NONO_ENV_FILE"
      fi
    fi
    gh_dir="$XDG_CACHE_HOME/nono/gh-config/$NONO_SESSION_ID"
    mkdir -p "$gh_dir"
    printf 'GH_CONFIG_DIR=%s\n' "$gh_dir" >> "$NONO_ENV_FILE"
  '';

  ghAfterHook = pkgs.writeShellScript "nono-agent-after" ''
    # Cleans up the per-session isolated GH_CONFIG_DIR. Runs outside the
    # sandbox after the child exits. Best-effort; no failure if absent.
    rm -rf "$XDG_CACHE_HOME/nono/gh-config/$NONO_SESSION_ID" 2>/dev/null || true
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
    home.file = profileFiles;
    # NONO_PROFILE selects the `agent` profile so per-call `-p agent` flags
    # aren't needed. This is read by the nono binary from its launching shell's
    # environment *before* the sandbox is applied; it isn't an agent env var, so
    # it doesn't appear in agentProfile.environment.allow_vars.
    home.sessionVariables.NONO_PROFILE = "agent";
  };
}
