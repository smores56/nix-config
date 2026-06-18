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

  # Least-privilege base every agent profile extends. nono's built-in `default`
  # already denies ~/.ssh, cloud creds, shell configs/history and keychains; on
  # top we grant the toolchains agents need (read-only, almost entirely /nix on
  # NixOS), a writable workdir, and deny ~/.config/gh so no agent can read the
  # gh OAuth token. That gh deny also hides maki's copilot provider, which would
  # otherwise probe gh/hosts.yml on every launch and 403. "no sudo" is structural:
  # /run/wrappers (the setuid sudo) is never granted, and child processes inherit
  # the kernel allow-list, so maki's bash tool cannot escalate either.
  baseProfile = {
    extends = "default";
    meta = {
      name = "agent-base";
      description = "Least-privilege base for coding agents: ro toolchains, rw workdir, no creds/sudo";
    };
    # All cross-platform groups (present in every nono build). The built-in
    # `default` profile is itself build-specific and already pulls in the right
    # per-OS system paths (linux core reads / macos system reads), so we only add
    # the language toolchains on top — no platform branching needed here.
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
      # bun runtime + bun-installed agents (pi/omp live in ~/.bun/bin on macOS;
      # on Linux they sit under $XDG_CACHE_HOME/.bun, already covered above).
      # wasmer/wasmtime are manually-installed WASM runtimes (outside /nix and
      # .cargo) that camp drives via its justfile; a read grant is exec here.
      # Hosts without them are a no-op — nono silently skips absent paths.
      read = [
        "$HOME/.bun"
        "$HOME/.wasmer"
        "$HOME/.wasmtime"
      ];
      deny = [ "$XDG_CONFIG_HOME/gh" ];
    };
  };

  # Each agent adds only its own state/config dirs on top of the base.
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

  # Per-host egress allowlist layered on the `developer` network profile
  # (llm_apis, package_registries, github, sigstore, documentation). brv's MCP
  # (*.byterover.dev) is allowed everywhere. The work machine adds only Codex
  # (auth.openai.com login/refresh + chatgpt.com Coding-Plan API; anthropic is
  # already in llm_apis) and NOT the personal LLM endpoints. Personal hosts
  # instead allow mimo / crofai / the local gemma host. Two trade-offs of
  # default-deny egress: (1) no general web search / arbitrary webfetch;
  # (2) nono's proxy only CONNECT-tunnels HTTPS, so the local plain-HTTP gemma
  # backend (smortress:8081) is unreachable — reach it via
  # dotfiles.nono.restrictNetwork = false, or on-host with `--open-port 8081`.
  agentDomains = [
    "*.byterover.dev"
  ] # brv MCP — all hosts
  ++ lib.optional cfWorkersAi "api.cloudflare.com" # maki — Cloudflare Workers AI inference
  ++ (
    if workModels then
      [
        "auth.openai.com" # codex — OAuth login + token refresh
        "chatgpt.com" # codex — Coding-Plan API (backend-api/codex)
        "sevenai-be.glean.com" # Glean MCP — work knowledge search/chat
        "slack.com" # Slack MCP — Web API
        "*.slack.com" # Slack MCP — workspace/API subdomains
      ]
    else
      [
        "token-plan-sgp.xiaomimimo.com" # xiaomi/mimo — personal default LLM
        "crof.ai" # crofai — kimi-k2.7-code backup
        "smortress" # local gemma host (HTTPS CONNECT only; gemma is plain-HTTP)
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
    enable =
      lib.mkEnableOption "the nono cross-platform agent sandbox (Landlock on Linux, Seatbelt on macOS)"
      // {
        default = true;
      };
    restrictNetwork =
      lib.mkEnableOption "default-deny agent egress via nono's developer network profile plus this config's LLM/MCP endpoints; disabling restores unrestricted network (web search, arbitrary webfetch)"
      // {
        default = true;
      };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ pkgs.nono ];
    home.file = profileFiles;
  };
}
