{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles;
  inherit (cfg) opencodeHost;

  minimax-m27 = "minimax/MiniMax-M2.7";

  opencodeSettings = {
    "$schema" = "https://opencode.ai/config.json";
    model = minimax-m27;
    small_model = minimax-m27;
    snapshot = false;
    compaction = {
      auto = true;
      prune = true;
      reserved = 16384;
      preserve_recent_tokens = 12000;
      tail_turns = 4;
    };
    tool_output = {
      max_lines = 150;
      max_bytes = 5000;
    };
    provider = {
      minimax.options.setCacheKey = true;
      deepseek.options.setCacheKey = true;
    };
    plugin = [
      "oh-my-openagent"
      "@tarquinen/opencode-smart-title"
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

  ohMyOpenagentConfig = {
    "$schema" =
      "https://raw.githubusercontent.com/code-yeongyu/oh-my-openagent/dev/assets/oh-my-opencode.schema.json";
    preset = "smores";
    fallback = {
      enabled = false;
    };
  };

  opencodeTui = {
    "$schema" = "https://opencode.ai/tui.json";
    plugin = [
      "oh-my-openagent"
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

          install_plugin "oh-my-openagent"
          install_plugin "@tarquinen/opencode-smart-title"
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
    "opencode/oh-my-openagent.json".text = builtins.toJSON ohMyOpenagentConfig;
    "opencode/smart-title.jsonc".text = builtins.toJSON { model = minimax-m27; };
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
