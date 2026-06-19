{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles.nono;
  workModels = config.dotfiles.workModels;
  cfWorkersAi = config.dotfiles.maki.cloudflareWorkersAi.enable;

  # Shared launcher for every agent site (abbrs, herdr pane, worktree spawns).
  # --allow-connect-port 22/443 has no JSON-profile equivalent (nono's `developer`
  # network profile only CONNECT-tunnels HTTPS; plain-ssh 22 + ssh.github.com:443
  # would otherwise be TCP-denied, blocking git push/pull). `exec` so nono
  # receives signals directly as the supervisor.
  # Usage: `nono-agent <profile> [cmd...]`; empty/flag cmd defaults to profile.
  agentWrapper = pkgs.writeShellScriptBin "nono-agent" ''
    profile="$1"; shift
    if [ "$#" -eq 0 ] || [[ "$1" == -* ]]; then
      set -- "$profile" "$@"
    fi
    exec nono run -s --allow-cwd \
      --allow-connect-port 22 --allow-connect-port 443 \
      -p "$profile" -- "$@"
  '';

  baseProfile = {
    extends = "default";
    meta = {
      name = "agent-base";
      description = "Least-privilege base for coding agents: ro toolchains, rw workdir, no creds/sudo";
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
      ];
      read = [
        "$HOME/.bun"
        "$HOME/.wasmer"
        "$HOME/.wasmtime"
        # ssh-agent socket lives here; granted as parent since nono skips
        # absent paths and the socket is created at login. ~/.ssh stays
        # denied by deny_credentials; only the public keys below are bypassed.
        "$XDG_RUNTIME_DIR"
      ];
      # Public keys non-secret; needed for git ssh-format signing + github host
      # verification. Private keys have no bypass, so signing/auth flows
      # through the agent socket.
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
      # Hides gh OAuth token; also suppresses maki's copilot provider probing.
      deny = [ "$XDG_CONFIG_HOME/gh" ];
    };
  };

  agentProfiles = {
    maki = {
      extends = "agent-base";
      meta = {
        name = "maki";
        description = "maki coding agent";
      };
      filesystem.allow = [
        "$XDG_CONFIG_HOME/maki"
        "$XDG_DATA_HOME/maki"
        "$XDG_STATE_HOME/maki"
        "$HOME/.local/logs/maki"
        "$HOME/.brv-cli"
      ];
    };
    pi = {
      extends = "agent-base";
      meta = {
        name = "pi";
        description = "pi primary agent";
      };
      filesystem.allow = [
        "$HOME/.pi"
        "$XDG_CONFIG_HOME/pi"
        "$XDG_DATA_HOME/pi"
        "$XDG_STATE_HOME/pi"
      ];
    };
    omp = {
      extends = "agent-base";
      meta = {
        name = "omp";
        description = "oh-my-pi backup agent";
      };
      filesystem.allow = [
        "$HOME/.omp"
        "$XDG_DATA_HOME/oh-my-pi-cli"
      ];
    };
  };

  # Egress allowlist on the `developer` network profile. proxy CONNECT-tunnels
  # HTTPS only, so the plain-HTTP local gemma host (smortress:8081) is
  # unreachable unless restrictNetwork=false or `--open-port 8081` on host.
  agentDomains = [
    "api.exa.ai" # maki websearch
    "*.byterover.dev" # brv MCP
  ]
  ++ lib.optional cfWorkersAi "api.cloudflare.com" # Cloudflare Workers AI
  ++ (
    if workModels then
      [
        "auth.openai.com" # codex OAuth
        "chatgpt.com" # codex Coding-Plan API
        "sevenai-be.glean.com" # Glean MCP
        "slack.com"
        "*.slack.com"
      ]
    else
      [
        "token-plan-sgp.xiaomimimo.com" # mimo
        "crof.ai" # crofai kimi-k2.7-code
        "api.neuralwatt.com" # neuralwatt
        "smortress" # local gemma (HTTPS CONNECT only)
      ]
  );
  networkAttrs = lib.optionalAttrs cfg.restrictNetwork {
    network = {
      network_profile = "developer";
      allow_domain = agentDomains;
    };
  };

  profileFiles = lib.mapAttrs' (
    name: profile:
    lib.nameValuePair ".config/nono/profiles/${name}.json" {
      force = true;
      text = builtins.toJSON profile;
    }
  ) ({ agent-base = baseProfile // networkAttrs; } // agentProfiles);
in
{
  options.dotfiles.nono = {
    restrictNetwork =
      lib.mkEnableOption "default-deny agent egress via nono's developer network profile plus this config's LLM/MCP endpoints; disabling restores unrestricted network"
      // {
        default = true;
      };
    agentWrapper = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      description = "nono-agent wrapper: `nono run -s --allow-cwd --allow-connect-port 22 --allow-connect-port 443 -p <profile> -- <cmd>`.";
    };
  };

  config = {
    home.packages = [
      pkgs.nono
      agentWrapper
    ];
    home.file = profileFiles;
    dotfiles.nono.agentWrapper = agentWrapper;
  };
}
