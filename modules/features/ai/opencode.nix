{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles;

  openchamberVersion = "1.11.3";

  models = {
    wafer-glm51 = "wafer/GLM-5.1";
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
        --port 3000 \
        --host 0.0.0.0 \
        --ui-password "$PASSPHRASE" \
        --foreground
    else
      exec ${pkgs.bun}/bin/bun x @openchamber/web@${openchamberVersion} serve \
        --port 3000 \
        --host 0.0.0.0 \
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
    ];
    provider.wafer = {
      npm = "@ai-sdk/openai-compatible";
      name = "Wafer";
      options.baseURL = "https://pass.wafer.ai/v1";
      models."GLM-5.1".name = "GLM 5.1";
    };
    server = {
      hostname = "0.0.0.0";
      port = 4000;
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
        mcps = [ "*" "!context7" ];
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
        mcps = [ "websearch" "context7" "grep_app" ];
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
    keybinds.leader = "ctrl+a";
  };
in
{
  home.packages = with pkgs; [
    opencode
    beads
    ocx
    openchamber
    openspec
  ];

  xdg.configFile."opencode/opencode.json" = {
    text = builtins.toJSON opencodeSettings;
  };

  xdg.configFile."opencode/tui.json" = {
    text = builtins.toJSON opencodeTui;
  };

  xdg.configFile."opencode/AGENTS.md" = {
    text = cfg.aiHints;
  };

  xdg.configFile."opencode/oh-my-opencode-slim.json" = {
    text = builtins.toJSON ohMyOpencodeSlimConfig;
  };

  xdg.configFile."opencode/smart-title.jsonc" = {
    text = builtins.toJSON {
      model = models.go-ds4flash;
    };
  };

  home.activation.setupOcxWorkspace = {
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

  home.activation.reloadOpencodeConfig = lib.mkIf cfg.opencodeServe {
    after = [ "linkGeneration" ];
    before = [ ];
    data = ''
      if systemctl --user is-active opencode.service >/dev/null 2>&1; then
        echo "[opencode] Reloading config..."
        systemctl --user restart opencode.service
      fi
    '';
  };

  systemd.user.services.opencode = lib.mkIf cfg.opencodeServe {
    Unit = {
      Description = "OpenCode Server";
      After = [ "network.target" ];
    };
    Service = {
      Environment = "PATH=${
        lib.makeBinPath [ pkgs.opencode ]
      }:${config.home.homeDirectory}/.nix-profile/bin";
      ExecStart = "${pkgs.opencode}/bin/opencode serve --port 4000";
      WorkingDirectory = config.home.homeDirectory;
      Restart = "always";
      RestartSec = 5;
    };
    Install = {
      WantedBy = [ "default.target" ];
    };
  };

  systemd.user.services.openchamber = lib.mkIf cfg.opencodeServe {
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
          ]
        }:${config.home.homeDirectory}/.nix-profile/bin"
        "OPENCODE_HOST=http://localhost:4000"
        "OPENCODE_SKIP_START=true"
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
}
