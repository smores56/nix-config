{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles;
  inherit (cfg) opencodeHost;

  models = {
    minimax-m27 = "deepseek/deepseek-v4-pro"; # temporarily switched from minimax/MiniMax-M2.7
    ds4pro = "deepseek/deepseek-v4-pro";
    ds4flash = "deepseek/deepseek-v4-flash";
  };

  opencodeSettings = {
    "$schema" = "https://opencode.ai/config.json";
    model = models.minimax-m27;
    small_model = models.ds4flash;
    plugin = [
      "oh-my-opencode-slim"
      "opencode-plugin-openspec"
      "opencode-beads"
      "@tarquinen/opencode-smart-title"
      "@tarquinen/opencode-dcp"
      "@slkiser/opencode-quota"
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
    mcp = {
      beads = {
        type = "local";
        command = [ "${config.home.homeDirectory}/.local/bin/beads-mcp" ];
        enabled = true;
      };
    };
  };

  ohMyOpencodeSlimConfig = {
    "$schema" = "https://unpkg.com/oh-my-opencode-slim@latest/oh-my-opencode-slim.schema.json";
    preset = "smores";
    disabled_agents = [ ];
    fallback = {
      enabled = true;
      timeoutMs = 15000;
      retryDelayMs = 500;
      retry_on_empty = true;
      chains = {
        orchestrator = [ models.ds4pro ];
        designer = [ models.ds4pro ];
        observer = [ models.ds4pro ];
        oracle = [ models.ds4flash ];
      };
    };
    presets.smores = {
      orchestrator = {
        model = models.minimax-m27;
        skills = [ "*" ];
        mcps = [
          "*"
          "!context7"
        ];
      };
      oracle = {
        model = models.ds4pro;
        variant = "high";
        skills = [ "simplify" ];
        mcps = [ ];
      };
      council = {
        model = models.ds4pro;
        variant = "high";
      };
      librarian = {
        model = models.minimax-m27;
        mcps = [
          "websearch"
          "context7"
          "grep_app"
        ];
      };
      explorer.model = models.minimax-m27;
      designer = {
        model = models.minimax-m27;
        variant = "medium";
      };
      fixer = {
        model = models.ds4flash;
        variant = "high";
      };
      observer.model = models.minimax-m27;
    };
  };

  quotaToastConfig = {
    enabled = true;
    enabledProviders = "auto";
    enableToast = true;
    tuiSidebarPanel.enabled = true;
    tuiCompactStatus.enabled = false;
    showSessionTokens = true;
    percentDisplayMode = "remaining";
    formatStyle = "singleWindow";
    maintainerAnnouncements.enabled = true;
  };

  opencodeTui = {
    "$schema" = "https://opencode.ai/tui.json";
    plugin = [
      "oh-my-opencode-slim"
      "@slkiser/opencode-quota"
      "caveman-opencode-plugin"
    ];
  };

  emptyLeftSessionSwitcher = ''
    export const id = "empty-left-session-switcher";

    export async function tui(api) {
      const keyInput = api.renderer.keyInput;

      const handler = (event) => {
        if (event.defaultPrevented) return;
        if (event.name !== "left") return;
        if (event.ctrl || event.meta || event.shift || event.super) return;
        if (api.ui.dialog.open) return;

        const route = api.route.current;
        if (route.name !== "home" && route.name !== "session") return;

        const focused = api.renderer.currentFocusedRenderable;
        if (!focused || focused.isDestroyed) return;
        if (typeof focused.plainText !== "string") return;
        if (focused.plainText.length !== 0) return;

        event.preventDefault();
        event.stopPropagation();
        api.command.trigger("session.list");
      };

      if (typeof keyInput.prependListener === "function") {
        keyInput.prependListener("keypress", handler);
      } else {
        keyInput.on("keypress", handler);
      }

      api.lifecycle.onDispose(() => {
        if (typeof keyInput.off === "function") {
          keyInput.off("keypress", handler);
          return;
        }
        if (typeof keyInput.removeListener === "function") {
          keyInput.removeListener("keypress", handler);
        }
      });
    }
  '';
in
{
  home = {
    sessionVariables.OPENCODE_MESSAGE_QUEUE_MODE = "hold";

    packages = with pkgs; [
      beads
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
          install_plugin "opencode-plugin-openspec"
          install_plugin "opencode-beads"
          install_plugin "@tarquinen/opencode-smart-title"
          install_plugin "@tarquinen/opencode-dcp"
          install_plugin "@slkiser/opencode-quota"
          install_plugin "caveman-opencode-plugin"
        '';
      };

      setupOcxWorkspace = {
        after = [ "linkGeneration" ];
        before = [ ];
        data = ''
          if [ -d "$HOME/.config/opencode/profiles/ws" ]; then
            echo "[ocx] Workspace profile configured"
          else
            echo "[ocx] Workspace profile not found"
          fi
        '';
      };

      installBeadsMcp = {
        after = [ "linkGeneration" ];
        before = [ ];
        data = ''
          export PATH="$HOME/.local/bin:$PATH"
          if ! command -v beads-mcp >/dev/null 2>&1; then
            echo "[beads] Installing beads-mcp..."
            ${pkgs.uv}/bin/uv tool install beads-mcp
          fi
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
    "opencode/plugins/empty-left-session-switcher.js".text = emptyLeftSessionSwitcher;
    "opencode/AGENTS.md".text = cfg.aiHints;
    "opencode/oh-my-opencode-slim.json".text = builtins.toJSON ohMyOpencodeSlimConfig;
    "opencode/smart-title.jsonc".text = builtins.toJSON {
      model = models.minimax-m27;
    };
    "opencode/caveman.json".text = builtins.toJSON {
      enabled = true;
      defaultMode = "full";
      features = {
        caveman = true;
        commit = true;
        review = true;
      };
    };
    "opencode-quota/quota-toast.json".text = builtins.toJSON quotaToastConfig;
  };
}
