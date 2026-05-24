{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles;
  inherit (cfg) opencodeHost;
  opencodeEnabled = opencodeHost.enable;
  opencodeBackendHost =
    if opencodeHost.bindAddress == "0.0.0.0" then "127.0.0.1" else opencodeHost.bindAddress;
  opencodeBackendUrl = "http://${opencodeBackendHost}:${toString opencodeHost.opencodePort}";

  models = {
    wafer-glm51 = "wafer/GLM-5.1";
    ds4pro = "deepseek/deepseek-v4-pro";
    ds4flash = "deepseek/deepseek-v4-flash";
  };

  openchamberBin = "${config.home.homeDirectory}/.cache/.bun/install/global/node_modules/@openchamber/web/bin/cli.js";

  opencodeSettings = {
    "$schema" = "https://opencode.ai/config.json";
    model = models.wafer-glm51;
    small_model = models.ds4flash;
    plugin = [
      "oh-my-opencode-slim"
      "opencode-plugin-openspec"
      "opencode-beads"
      "@tarquinen/opencode-smart-title"
    ];
    server = {
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
        model = models.wafer-glm51;
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
        model = models.ds4flash;
        mcps = [
          "websearch"
          "context7"
          "grep_app"
        ];
      };
      explorer.model = models.ds4flash;
      designer = {
        model = models.wafer-glm51;
        variant = "medium";
      };
      fixer = {
        model = models.ds4flash;
        variant = "high";
      };
      observer.model = models.wafer-glm51;
    };
  };

  opencodeTui = {
    "$schema" = "https://opencode.ai/tui.json";
    keybinds.leader = "ctrl+e";
    plugin = [ "oh-my-opencode-slim" ];
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

      reloadOpencodeConfig = lib.mkIf cfg.opencodeServe {
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
      model = models.ds4flash;
    };
  };

  systemd.user.services = {
    opencode = lib.mkIf cfg.opencodeServe {
      Unit = {
        Description = "OpenCode Server";
        After = [ "network.target" ];
      };
      Service = {
        Environment = [
          "OPENCODE_HOST=http://localhost:4000"
        ];
        ExecStart = "${config.home.homeDirectory}/.opencode/bin/opencode serve --hostname ${opencodeHost.bindAddress} --port ${toString opencodeHost.opencodePort}";
        WorkingDirectory = config.home.homeDirectory;
        Restart = "always";
        RestartSec = 5;
      };
      Install = {
        WantedBy = [ "default.target" ];
      };
    };

    openchamber = lib.mkIf (opencodeEnabled && pkgs.stdenv.isLinux) {
      Unit = {
        Description = "OpenChamber Web UI";
        After = [
          "network.target"
          "opencode.service"
        ];
        Requires = [ "opencode.service" ];
      };
      Service = {
        Environment = [
          "OPENCODE_HOST=${opencodeBackendUrl}"
          "OPENCODE_BINARY=${config.home.homeDirectory}/.opencode/bin/opencode"
          "OPENCODE_SKIP_START=true"
        ];
        ExecStart = pkgs.writeShellScript "openchamber-serve" ''
          PASSWORD=""
          if [ -f "${config.home.homeDirectory}/.config/openchamber/ui-password" ] && [ -s "${config.home.homeDirectory}/.config/openchamber/ui-password" ]; then
            IFS= read -r PASSWORD < "${config.home.homeDirectory}/.config/openchamber/ui-password"
          fi
          exec ${openchamberBin} serve \
            --port ${toString opencodeHost.openchamberPort} \
            --host ${lib.escapeShellArg opencodeHost.bindAddress} \
            --ui-password "$PASSWORD" \
            --foreground
        '';
        WorkingDirectory = config.home.homeDirectory;
        Restart = "always";
        RestartSec = 5;
      };
      Install = {
        WantedBy = [ "default.target" ];
      };
    };
  };

  launchd.agents = {
    opencode = lib.mkIf (opencodeEnabled && pkgs.stdenv.isDarwin) {
      enable = true;
      config = {
        ProgramArguments = [
          "${config.home.homeDirectory}/.opencode/bin/opencode"
          "serve"
          "--hostname"
          opencodeHost.bindAddress
          "--port"
          (toString opencodeHost.opencodePort)
        ];
        WorkingDirectory = config.home.homeDirectory;
        EnvironmentVariables = {
          OPENCODE_MESSAGE_QUEUE_MODE = "hold";
        };
        KeepAlive = true;
        RunAtLoad = true;
        StandardOutPath = "${config.home.homeDirectory}/Library/Logs/opencode.log";
        StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/opencode.error.log";
      };
    };

    openchamber = lib.mkIf (opencodeEnabled && pkgs.stdenv.isDarwin) {
      enable = true;
      config = {
        ProgramArguments = [
          "${openchamberBin}"
          "serve"
          "--port"
          (toString opencodeHost.openchamberPort)
          "--host"
          opencodeHost.bindAddress
          "--foreground"
        ];
        WorkingDirectory = config.home.homeDirectory;
        EnvironmentVariables = {
          OPENCODE_HOST = opencodeBackendUrl;
          OPENCODE_SKIP_START = "true";
        };
        KeepAlive = true;
        RunAtLoad = true;
        StandardOutPath = "${config.home.homeDirectory}/Library/Logs/openchamber.log";
        StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/openchamber.error.log";
      };
    };
  };
}
