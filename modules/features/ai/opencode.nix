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

  openchamberVersion = "1.11.4";

  models = {
    wafer-glm51 = "wafer/GLM-5.1";
    openai-codex = "openai/gpt-5.3-codex";
    anthropic-sonnet = "anthropic/claude-sonnet-4-5";
    go-ds4pro = "opencode-go/deepseek-v4-pro";
    go-ds4flash = "opencode-go/deepseek-v4-flash";
    go-minimax = "opencode-go/minimax-m2.7";
    go-kimi = "opencode-go/kimi-k2.6";
  };

  openspec = pkgs.writeShellScriptBin "openspec" ''
    exec ${pkgs.bun}/bin/bun x @fission-ai/openspec@latest "$@"
  '';

  openchamber = pkgs.writeShellScriptBin "openchamber" ''
    exec ${pkgs.bun}/bin/bun x @openchamber/web@${openchamberVersion} "$@"
  '';

  openchamberServe = pkgs.writeShellScriptBin "openchamber-serve" ''
    set -e
    PASSPHRASE_FILE="${config.home.homeDirectory}/.config/openchamber/ui-password"
    if [ -f "$PASSPHRASE_FILE" ] && [ -s "$PASSPHRASE_FILE" ]; then
      IFS= read -r PASSPHRASE < "$PASSPHRASE_FILE"
      exec ${pkgs.bun}/bin/bun x @openchamber/web@${openchamberVersion} serve \
        --port ${toString opencodeHost.openchamberPort} \
        --host ${lib.escapeShellArg opencodeHost.bindAddress} \
        --ui-password "$PASSPHRASE" \
        --foreground
    else
      exec ${pkgs.bun}/bin/bun x @openchamber/web@${openchamberVersion} serve \
        --port ${toString opencodeHost.openchamberPort} \
        --host ${lib.escapeShellArg opencodeHost.bindAddress} \
        --foreground
    fi
  '';

  ocx = pkgs.writeShellScriptBin "ocx" ''
    exec ${pkgs.bun}/bin/bun x ocx@2.0.11 "$@"
  '';

  opencodeSettings = {
    "$schema" = "https://opencode.ai/config.json";
    model = models.wafer-glm51;
    small_model = models.go-ds4flash;
    plugin = [
      "oh-my-opencode-slim"
      "opencode-plugin-openspec"
      "opencode-beads"
      "@tarquinen/opencode-smart-title"
      "@0xsero/open-queue"
    ];
    provider.wafer = {
      npm = "@ai-sdk/openai-compatible";
      name = "Wafer";
      options.baseURL = "https://pass.wafer.ai/v1";
      models."GLM-5.1".name = "GLM 5.1";
    };
    server = {
      hostname = opencodeHost.bindAddress;
      port = opencodeHost.opencodePort;
    };
    agent = {
      codex = {
        model = models.openai-codex;
        mode = "primary";
        description = "OpenAI Codex-backed primary coding agent.";
      };
      claude = {
        model = models.anthropic-sonnet;
        mode = "primary";
        description = "Anthropic Claude-backed primary coding agent.";
      };
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
        orchestrator = [ models.go-ds4pro ];
        oracle = [ models.go-ds4pro ];
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
        model = models.wafer-glm51;
        variant = "high";
        skills = [ "simplify" ];
        mcps = [ ];
      };
      council = {
        model = models.go-ds4pro;
        variant = "high";
      };
      librarian = {
        model = models.go-minimax;
        mcps = [
          "websearch"
          "context7"
          "grep_app"
        ];
      };
      explorer.model = models.go-minimax;
      designer = {
        model = models.go-kimi;
        variant = "medium";
      };
      fixer = {
        model = models.go-ds4flash;
        variant = "high";
      };
      observer.model = models.go-kimi;
    };
  };

  opencodeTui = {
    "$schema" = "https://opencode.ai/tui.json";
    keybinds.leader = "ctrl+space";
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
      opencode
      beads
      ocx
      openchamber
      openspec
      gnumake
      gcc
    ];

    activation = {
      installOpencodePlugins = {
        after = [ "linkGeneration" ];
        before = [ ];
        data = ''
          export PATH="${
            lib.makeBinPath [
              pkgs.nodejs
              pkgs.opencode
            ]
          }:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

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
      model = models.go-ds4flash;
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
          "PATH=${
            lib.makeBinPath [
              pkgs.opencode
              pkgs.gnumake
              pkgs.gcc
            ]
          }:${config.home.homeDirectory}/.nix-profile/bin"
          "OPENCODE_HOST=http://localhost:4000"
          "OPENCODE_DISABLE_AUTOUPDATE=true"
        ];
        ExecStart = "${pkgs.opencode}/bin/opencode serve --hostname ${opencodeHost.bindAddress} --port ${toString opencodeHost.opencodePort}";
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
        BindsTo = [ "opencode.service" ];
      };
      Service = {
        Environment = [
          "PATH=${
            lib.makeBinPath [
              pkgs.bun
              pkgs.nodejs
              pkgs.gnumake
              pkgs.gcc
            ]
          }:${config.home.homeDirectory}/.nix-profile/bin"
          "OPENCODE_HOST=${opencodeBackendUrl}"
          "OPENCODE_SKIP_START=true"
          "OPENCODE_DISABLE_AUTOUPDATE=true"
        ];
        ExecStart = "${openchamberServe}/bin/openchamber-serve";
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
          "${pkgs.opencode}/bin/opencode"
          "serve"
          "--hostname"
          opencodeHost.bindAddress
          "--port"
          (toString opencodeHost.opencodePort)
        ];
        WorkingDirectory = config.home.homeDirectory;
        EnvironmentVariables = {
          PATH = "${
            lib.makeBinPath [ pkgs.opencode ]
          }:${config.home.homeDirectory}/.nix-profile/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin";
          OPENCODE_MESSAGE_QUEUE_MODE = "hold";
          OPENCODE_DISABLE_AUTOUPDATE = "true";
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
        ProgramArguments = [ "${openchamberServe}/bin/openchamber-serve" ];
        WorkingDirectory = config.home.homeDirectory;
        EnvironmentVariables = {
          PATH = "${
            lib.makeBinPath [
              pkgs.bun
              pkgs.nodejs
            ]
          }:${config.home.homeDirectory}/.nix-profile/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin";
          OPENCODE_HOST = opencodeBackendUrl;
          OPENCODE_SKIP_START = "true";
          OPENCODE_DISABLE_AUTOUPDATE = "true";
        };
        KeepAlive = true;
        RunAtLoad = true;
        StandardOutPath = "${config.home.homeDirectory}/Library/Logs/openchamber.log";
        StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/openchamber.error.log";
      };
    };
  };
}
