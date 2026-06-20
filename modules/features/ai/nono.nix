{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles.nono;

  # Shared launcher for every agent site (abbrs, herdr pane, worktree spawns).
  # First arg is the command, not a profile name. For dangerous/unsubnetted
  # edits, run `exec maki` directly (shorter than the safe path, on purpose).
  # Only the worktree-spawn caller prepends `exec` (so nono becomes the
  # detached session leader for signal/job-control).
  agentWrapper = pkgs.writeShellScriptBin "nono-agent" ''
    if [ "$#" -eq 0 ]; then
      echo "nono-agent: missing command (e.g. \`nono-agent maki\`)" >&2
      exit 64
    fi
    nono run -s --allow-cwd -p agent -- "$@"
  '';

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
      description = "Shared least-privilege profile for coding agents (maki/pi/omp): open network, filtered env, denied creds/sudo";
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
      # denying it hides both. gh itself runs outside the sandbox.
      deny = [
        "$XDG_CONFIG_HOME/fish/conf.d"
        "$XDG_CONFIG_HOME/gh"
      ];
    };
    # With network open, inherited shell secrets are both readable and
    # exfiltrable, so this allow-list is the primary secret control. nono's
    # non-overridable blocklist (LD_PRELOAD, DYLD_*, PYTHONPATH, NODE_OPTIONS)
    # is enforced regardless. Agents don't read GH_TOKEN/GITHUB_TOKEN (git
    # auth is ssh-agent signing + gh outside the sandbox).
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
  };

  profileFiles = {
    ".config/nono/profiles/agent.json" = {
      force = true;
      text = builtins.toJSON agentProfile;
    };
  };
in
{
  options.dotfiles.nono = {
    enable = lib.mkEnableOption "nono sandbox for coding agents (maki/pi/omp) with open networking and env-var filtering" // {
      default = true;
    };
    agentWrapper = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      description = "nono-agent wrapper: `nono run -s --allow-cwd -p agent -- <cmd>`.";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [
      pkgs.nono
      agentWrapper
    ];
    home.file = profileFiles;
    dotfiles.nono.agentWrapper = agentWrapper;
  };
}
