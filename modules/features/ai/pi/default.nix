{
  config,
  lib,
  pkgs,
  aiXiaomi,
  aiDeepseek,
  aiCrofai,
  ...
}:
let
  cfg = config.dotfiles.pi;
  dashboardCfg = config.dotfiles.piDashboard;
  workModels = config.dotfiles.workModels;
  homeDir = config.home.homeDirectory;
  agentDir = "${homeDir}/.pi/agent";

  piPackage = "@earendil-works/pi-coding-agent";
  piPrivateDir = "${homeDir}/.local/share/pi-cli";
  piEntrypoint = "${piPrivateDir}/node_modules/${piPackage}/src/cli.ts";

  bunBin = "${homeDir}/.bun/bin";
  piCli = "${bunBin}/pi";
  jqBin = "${pkgs.jq}/bin/jq";

  stylixColors = config.lib.stylix.colors;
  powerlineTheme = builtins.toJSON {
    colors = {
      model = "#${stylixColors.base0D}";
      shellMode = "accent";
      path = "#${stylixColors.base0C}";
      gitDirty = "warning";
      gitClean = "success";
      thinking = "thinkingOff";
      thinkingMinimal = "thinkingMinimal";
      thinkingLow = "thinkingLow";
      thinkingMedium = "thinkingMedium";
      context = "dim";
      contextWarn = "warning";
      contextError = "error";
      cost = "text";
      tokens = "muted";
      separator = "dim";
      border = "borderMuted";
    };
  };

  piWrapper = pkgs.writeShellScriptBin "pi" ''
    set -euo pipefail

    export PATH="${bunBin}:$HOME/.cache/.bun/bin:$PATH"

    if [ -z "''${OPENAI_CODEX_OAUTH_TOKEN:-}" ] && [ -r "$HOME/.codex/auth.json" ]; then
      token="$(${jqBin} -r '.tokens.access_token // empty' "$HOME/.codex/auth.json" 2>/dev/null || true)"
      if [ -n "$token" ] && [ "$token" != "null" ]; then
        export OPENAI_CODEX_OAUTH_TOKEN="$token"
      fi
    fi

    if [ -z "''${ANTHROPIC_OAUTH_TOKEN:-}" ] && [ -r "$HOME/.claude/.credentials.json" ]; then
      token="$(${jqBin} -r '.claudeAiOauth.accessToken // empty' "$HOME/.claude/.credentials.json" 2>/dev/null || true)"
      if [ -n "$token" ] && [ "$token" != "null" ]; then
        export ANTHROPIC_OAUTH_TOKEN="$token"
      fi
    fi

    if [ -r "${piEntrypoint}" ]; then
      exec "${bunBin}/bun" "${piEntrypoint}" "$@"
    fi

    echo "Pi CLI not installed. Run home-manager switch or install ${piPackage} into ${piPrivateDir}." >&2
    exit 127
  '';

  modelsConfig =
    if workModels then
      { }
    else
      {
        providers = {
          ${aiXiaomi.providerId} = {
            baseUrl = aiXiaomi.baseUrl;
            apiKey = "$XIAOMI_MIMO_API_KEY";
            api = "openai-completions";
            models = aiXiaomi.ompModelsList;
          };
          smortress = {
            baseUrl = "http://smortress:8081/v1";
            api = "openai-completions";
            apiKey = "none";
            compat = {
              supportsDeveloperRole = false;
            };
            models = [
              {
                id = "gemma-4-31b";
                name = "Gemma 4 31B (smortress)";
                reasoning = true;
                input = [ "text" ];
                contextWindow = 102400;
                maxTokens = 102400;
                cost = {
                  input = 0;
                  output = 0;
                  cacheRead = 0;
                  cacheWrite = 0;
                };
              }
            ];
          };
          ${aiDeepseek.providerId} = {
            baseUrl = aiDeepseek.baseUrl;
            apiKey = "$DEEPSEEK_API_KEY";
            api = "openai-completions";
            models = aiDeepseek.ompModelsList;
          };
          ${aiCrofai.providerId} = {
            baseUrl = aiCrofai.baseUrl;
            apiKey = "$CROFAI_API_KEY";
            api = "openai-completions";
            models = aiCrofai.ompModelsList;
          };
        };
      };

  dashboardConfig = lib.mkIf dashboardCfg.enable {
    home.activation.configurePiDashboard = {
      after = [ "linkGeneration" ];
      before = [ ];
      data = ''
                CONFIG_DIR="$HOME/.pi/dashboard"
                mkdir -p "$CONFIG_DIR"
                cat > "$CONFIG_DIR/config.json" << 'DASHBOARD_CFG'
            {
              "port": ${toString dashboardCfg.port},
              "host": "127.0.0.1",
              "disableZrokTunnel": true
            }
        DASHBOARD_CFG
      '';
    };

    systemd.user.services.pi-dashboard = {
      Unit = {
        Description = "Pi Agent Dashboard (pi.sammohr.dev)";
        After = [ "network-online.target" ];
        Wants = [ "network-online.target" ];
      };

      Service = {
        Type = "simple";
        Environment =
          "PATH=${pkgs.nodejs}/bin:${bunBin}:%h/.cache/.bun/bin:%h/.local/share/pi-cli/node_modules/.bin:/run/wrappers/bin"
          + " PUBLIC_URL=https://pi.sammohr.dev";
        ExecStart = "${pkgs.nodejs}/bin/node --import file://${agentDir}/npm/node_modules/jiti/lib/jiti-register.mjs ${agentDir}/npm/node_modules/@blackbelt-technology/pi-agent-dashboard/packages/server/src/cli.ts";
        Restart = "on-failure";
        RestartSec = 5;
      };

      Install = {
        WantedBy = [ "default.target" ];
      };
    };
  };

in
{
  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      home.packages = [ piWrapper ];

      home.file."${agentDir}/settings.json".text = builtins.toJSON {
        defaultProvider = cfg.defaultProvider;
        defaultModel = cfg.defaultModel;
        defaultThinkingLevel = cfg.defaultThinkingLevel;
        enableInstallTelemetry = false;
        quietStartup = true;
        collapseChangelog = true;
        doubleEscapeAction = "tree";
        compaction = {
          enabled = true;
          reserveTokens = cfg.compaction.reserveTokens;
          keepRecentTokens = cfg.compaction.keepRecentTokens;
        };
        retry = {
          enabled = true;
          maxRetries = 2;
          baseDelayMs = 2000;
        };
        steeringMode = "one-at-a-time";
        followUpMode = "one-at-a-time";
      };

      home.file."${agentDir}/models.json" = {
        force = true;
        text = builtins.toJSON modelsConfig;
      };
      # Extensions
      home.file."${agentDir}/extensions/terminal-bell.ts".source = ./extensions/terminal-bell.ts;
      home.file."${agentDir}/extensions/filter-output.ts".source = ./extensions/filter-output.ts;
      home.file."${agentDir}/extensions/handoff.ts".source = ./extensions/handoff.ts;
      home.file."${agentDir}/extensions/plan-mode.ts".source = ../oh-my-pi/plan-mode.ts;
      home.file."${agentDir}/extensions/cost.ts".source = ./extensions/cost.ts;

      # Skills
      home.file."${agentDir}/skills/grill-me/SKILL.md".source = ./skills/grill-me/SKILL.md;

      # APPEND_SYSTEM.md
      home.file."${agentDir}/APPEND_SYSTEM.md".source = ./APPEND_SYSTEM.md;

      # Install CLI on activation
      home.activation.installPiCli = {
        after = [ "linkGeneration" ];
        before = [ "installPiPackages" ];
        data = ''
          if [ -r "${piEntrypoint}" ]; then
            echo "[pi] CLI already installed"
          elif ! command -v "${bunBin}/bun" >/dev/null 2>&1; then
            echo "[pi] bun not found at ${bunBin}/bun, cannot install ${piPackage}" >&2
          else
            echo "[pi] Installing ${piPackage} into ${piPrivateDir}"
            mkdir -p "${piPrivateDir}"
            printf '%s\n' '{"private":true,"dependencies":{"${piPackage}":"latest"}}' > "${piPrivateDir}/package.json"
            if ! (cd "${piPrivateDir}" && "${bunBin}/bun" install); then
              echo "[pi] Failed to install ${piPackage}" >&2
            fi
          fi
        '';
      };

      # Install pi packages
      home.activation.installPiPackages = {
        after = [
          "linkGeneration"
          "installPiCli"
        ];
        before = [ "writePowerlineTheme" ];
        data = ''
          if [ ! -x "${piCli}" ]; then
            echo "[pi] pi CLI not found at ${piCli}, skipping package install"
          elif ! "${piCli}" list >/dev/null 2>&1; then
            echo "[pi] pi CLI not runnable, skipping package install"
          else
            install_pkg() {
              local name="$1"
              local short
              short="$(echo "$name" | sed 's|.*/||')"
              if ! "${piCli}" list 2>/dev/null | grep -q "$short"; then
                echo "[pi] Installing $name"
                "${piCli}" install "$name" 2>&1 || true
              fi
            }

            ${lib.concatStringsSep "\n" (map (pkg: "            install_pkg \"${pkg}\"") cfg.packages)}
          fi
        '';
      };

      # Write powerline theme
      home.activation.writePowerlineTheme = {
        after = [ "installPiPackages" ];
        before = [ ];
        data = ''
                    mkdir -p "${agentDir}/npm/node_modules/pi-powerline-footer"
                    cat > "${agentDir}/npm/node_modules/pi-powerline-footer/theme.json" << 'PLTHEME'
            ${powerlineTheme}
          PLTHEME
        '';
      };

      programs.fish.shellAbbrs = lib.mkIf cfg.fishAbbrs {
        pi = "pi";
        pip = "pi -p";
        pic = "pi -c";
      };
    })
    dashboardConfig
  ];
}
