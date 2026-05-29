{
  config,
  lib,
  pkgs,
  aiCrofai,
  ...
}:
let
  cfg = config.dotfiles;
  inherit (cfg) opencodeHost;
  roles = aiCrofai.roles;

  # CrofAI Scale is request-capped, not token-capped. Shared routing lives in
  # ../crofai.nix so OpenCode and oh-my-pi cannot drift.

  opencodeSettings = {
    "$schema" = "https://opencode.ai/config.json";
    model = roles.default;
    small_model = roles.smol;
    snapshot = false;
    compaction = {
      auto = true;
      prune = true;
      reserved = 32768;
      preserve_recent_tokens = 48000;
      tail_turns = 8;
    };
    tool_output = {
      max_lines = 300;
      max_bytes = 20000;
    };
    provider = {
      ${aiCrofai.providerId} = {
        npm = "@ai-sdk/openai-compatible";
        name = "CrofAI";
        options.baseURL = aiCrofai.baseUrl;
        models = aiCrofai.opencodeModels;
      };
    };
    plugin = [
      "oh-my-opencode-slim"
      "@tarquinen/opencode-dcp"
      "caveman-opencode-plugin"
    ];

    server = lib.optionalAttrs (opencodeHost.bindAddress != null) {
      hostname = opencodeHost.bindAddress;
      port = opencodeHost.opencodePort;
    };
    command.queue = {
      description = "Control message queue mode (hold/immediate/status)";
      template = ''
        Use the queue tool with action: $ARGUMENTS.
        Only change queue mode when the user explicitly asks.
        Do not switch to immediate on your own.
        If no argument provided, use action "status" to show current state.
      '';
    };
  };

  # Slim keeps orchestration available without oh-my-openagent's high-request
  # team/council loops. Fallbacks and auto-continuation stay off so a bad or
  # empty response cannot silently multiply requests.
  ohMyOpencodeSlimConfig = {
    "$schema" = "https://unpkg.com/oh-my-opencode-slim@latest/oh-my-opencode-slim.schema.json";
    preset = "crofai-scale";
    autoUpdate = false;
    disabled_agents = [
      "observer"
      "council"
    ];
    fallback.enabled = false;
    sessionManager = {
      maxSessionsPerAgent = 1;
      readContextMinLines = 30;
      readContextMaxFiles = 4;
    };
    todoContinuation = {
      autoEnable = false;
      maxContinuations = 1;
    };
    # Agent roles mirror oh-my-pi modelRoles so both harnesses spend requests
    # predictably. Use more context per call instead of spawning helper calls.
    presets.crofai-scale = {
      orchestrator = {
        model = roles.default;
        variant = "medium";
        skills = [ "*" ];
        mcps = [ ];
      };
      oracle = {
        model = roles.slow;
        variant = "high";
        skills = [ "simplify" ];
        mcps = [ ];
      };
      librarian = {
        model = roles.smol;
        variant = "low";
        skills = [ ];
        mcps = [
          "websearch"
          "grep_app"
        ];
      };
      explorer = {
        model = roles.smol;
        variant = "low";
        skills = [ ];
        mcps = [ ];
      };
      designer = {
        model = roles.vision;
        variant = "medium";
        skills = [ ];
        mcps = [ ];
      };
      fixer = {
        model = roles.task;
        variant = "medium";
        skills = [ ];
        mcps = [ ];
      };
    };
  };

  opencodeTui = {
    "$schema" = "https://opencode.ai/tui.json";
    plugin = [
      "oh-my-opencode-slim"
      "caveman-opencode-plugin"
    ];
  };
in
{
  home = {
    sessionVariables.OPENCODE_MESSAGE_QUEUE_MODE = "hold";

    packages = with pkgs; [
      bun
      nodejs
      gnumake
      gcc
    ];

    activation = {
      installOpencodePlugins = {
        after = [ "linkGeneration" ];
        before = [ ];
        data = ''
          export PATH="$HOME/.opencode/bin:$PATH"

          if ! command -v opencode >/dev/null 2>&1; then
            echo "[opencode] opencode not found in PATH, skipping plugin install"
            exit 0
          fi

          install_plugin() {
            local name="$1"
            local pkg_dir="$HOME/.cache/opencode/packages/$name@latest"
            if [ ! -d "$pkg_dir/node_modules/$name" ]; then
              opencode plugin "$name" --global --force 2>&1 || true
            fi
          }

          install_plugin "oh-my-opencode-slim"
          install_plugin "@tarquinen/opencode-dcp"
          install_plugin "caveman-opencode-plugin"
        '';
      };

      reloadOpencodeConfig = lib.mkIf (cfg.opencodeHost.bindAddress != null) {
        after = [ "linkGeneration" ];
        before = [ ];
        data = ''
          if systemctl --user is-active opencode.service >/dev/null 2>&1; then
            echo "[opencode] Reloading config..."
            systemctl --user restart opencode.service
          fi
        '';
      };
    };
  };

  xdg.configFile = {
    "opencode/opencode.json".text = builtins.toJSON opencodeSettings;
    "opencode/tui.json".text = builtins.toJSON opencodeTui;
    "opencode/AGENTS.md".text = cfg.aiHints;
    "opencode/oh-my-opencode-slim.json".text = builtins.toJSON ohMyOpencodeSlimConfig;
    "opencode/caveman.json".text = builtins.toJSON {
      enabled = true;
      defaultMode = "full";
      features = {
        caveman = true;
        commit = true;
        review = true;
      };
    };
  };
}
