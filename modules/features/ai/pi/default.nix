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
  npmDir = "${agentDir}/npm";

  piPackage = "@earendil-works/pi-coding-agent";
  piPrivateDir = "${homeDir}/.local/share/pi-cli";
  piEntrypoint = "${piPrivateDir}/node_modules/${piPackage}/src/cli.ts";

  bunBin = "${homeDir}/.bun/bin";

  bordoVars = (builtins.fromJSON (builtins.readFile ./themes/noctis-bordo.json)).vars;
  powerlineTheme = builtins.toJSON {
    colors = {
      model = bordoVars.rose;
      shellMode = "accent";
      path = bordoVars.cyan;
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

  piPackages = [
    "npm:pi-total-recall"
    "npm:pi-rtk-optimizer"
    "npm:pi-subagents"
    "npm:pi-mcp-adapter"
    "npm:pi-web-access"
    "npm:pi-intercom"
    "npm:pi-powerline-footer"
    "npm:pi-autoresearch"
    "npm:pi-review-loop"
    "npm:@juicesharp/rpiv-ask-user-question"
  ]
  ++ cfg.packages;

  # Extract npm package name from source (strip npm: prefix, take last segment after /)
  pkgName =
    source:
    let
      s = lib.last (builtins.split "/" source);
    in
    if lib.hasPrefix "npm:" source then
      builtins.substring 4 (builtins.stringLength source) source
    else
      s;

  # Two-tier subagent hierarchy for the pi-subagents plugin's builtin agents.
  # The parent session (cfg.defaultModel) is the strong tier; cheap/scout work
  # is delegated to the weak tier. deepseek + crofai stay available as failover
  # backups via fallbackModels.
  strongModel = if workModels then "anthropic/claude-fable-5" else cfg.defaultModel;
  weakModel =
    if workModels then
      "anthropic/claude-sonnet-4-6"
    else
      "${aiXiaomi.providerId}/${aiXiaomi.models.mimoV25.id}";

  strongBackups = [
    "${aiDeepseek.providerId}/${aiDeepseek.models.v4Pro.id}"
    "${aiCrofai.providerId}/${aiCrofai.models.glm51.id}"
    "smortress/gemma-4-31b"
  ];
  weakBackups = [
    "${aiDeepseek.providerId}/${aiDeepseek.models.v4Flash.id}"
    "${aiCrofai.providerId}/${aiCrofai.models.glm51.id}"
    "smortress/gemma-4-31b"
  ];

  mkAgentOverride = model: fallbackModels: { inherit model fallbackModels; };

  # Aggressive tiering mirrors oh-my-pi: scouts + general implementation
  # (scout/researcher/worker/delegate) go weak; planning, review, oracle, and
  # the stronger context pass stay on the strong tier.
  subagentOverrides = builtins.listToAttrs (
    map
      (name: {
        inherit name;
        value = mkAgentOverride weakModel weakBackups;
      })
      [
        "scout"
        "researcher"
        "worker"
        "delegate"
      ]
    ++
      map
        (name: {
          inherit name;
          value = mkAgentOverride strongModel strongBackups;
        })
        [
          "planner"
          "reviewer"
          "oracle"
          "context-builder"
        ]
  );

  modelsConfig =
    if workModels then
      {
        providers = {
          # Fable 5 (released 2026-06-09) isn't in pi's bundled model catalog yet.
          # Merge it into the built-in anthropic provider so the endpoint and OAuth
          # auth are inherited; fields mirror the native claude-opus-4-8 entry, the
          # model Fable's safeguards fall back to. Pricing per Anthropic's launch
          # post ($10/$50 per Mtok; 0.1x cache read, 1.25x cache write).
          anthropic.models = [
            {
              id = "claude-fable-5";
              name = "Claude Fable 5";
              api = "anthropic-messages";
              reasoning = true;
              thinkingLevelMap.xhigh = "xhigh";
              compat.forceAdaptiveThinking = true;
              input = [
                "text"
                "image"
              ];
              contextWindow = 1000000;
              maxTokens = 128000;
              cost = {
                input = 10;
                output = 50;
                cacheRead = 1;
                cacheWrite = 12.5;
              };
            }
          ];
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
      }
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
      home.file."${agentDir}/settings.json" = {
        force = true;
        text = builtins.toJSON {
          defaultProvider = cfg.defaultProvider;
          defaultModel = cfg.defaultModel;
          defaultThinkingLevel = cfg.defaultThinkingLevel;
          theme = "noctis-bordo";
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
          packages = piPackages;
          subagents = {
            agentOverrides = subagentOverrides;
          };
        };
      };

      home.file."${agentDir}/models.json" = {
        force = true;
        text = builtins.toJSON modelsConfig;
      };

      # Skills
      home.file."${agentDir}/skills/grill-me/SKILL.md".source = ./skills/grill-me/SKILL.md;

      # Themes
      home.file."${agentDir}/themes/noctis-bordo.json".source = ./themes/noctis-bordo.json;

      # Extensions
      home.file."${agentDir}/extensions/plan-mode.ts".source = ../oh-my-pi/plan-mode.ts;

      # APPEND_SYSTEM.md
      home.file."${agentDir}/APPEND_SYSTEM.md".source = ./APPEND_SYSTEM.md;
      home.file."${agentDir}/extensions/code-execution.ts".source = ./extensions/code-execution.ts;

      home.file."${homeDir}/.config/fish/conf.d/pi-aliases.fish".text = ''
        function p --wraps 'gmux pi' --description 'p: gmux pi'
          FISH_TERMINAL_SKIP_DSR=1 gmux pi $argv
        end
        function pip --wraps 'pi -p' --description 'pip: pi -p'
          pi -p $argv
        end
        function pic --wraps 'pi -c' --description 'pic: pi -c'
          pi -c $argv
        end
      '';
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

      # Install pi npm packages into agent npm dir
      # settings.json is nix-managed (store path), so pi install can't write to it
      # We install via bun add + inline packages in settings.json
      home.activation.installPiPackages = {
        after = [ "linkGeneration" ];
        before = [ "installPiMonty" ];
        data = ''
          NPM_DIR="${npmDir}"
          mkdir -p "$NPM_DIR"
          ${lib.concatStringsSep "\n" (
            map (source: ''
              NAME="${pkgName source}"
              if ! [ -d "$NPM_DIR/node_modules/$NAME" ]; then
                echo "[pi] Installing $NAME"
                (cd "$NPM_DIR" && "${bunBin}/bun" add "$NAME" 2>&1) || true
              fi
            '') piPackages
          )}
        '';
      };
      home.activation.installPiMonty = {
        after = [ "installPiPackages" ];
        before = [ ];
        data = ''
          if [ ! -d "${piPrivateDir}" ]; then
            echo "[pi] piPrivateDir missing, skipping monty install"
          else
            echo "[pi] Installing @pydantic/monty into pi node_modules"
            (cd "${piPrivateDir}" && "${bunBin}/bun" add @pydantic/monty 2>&1) || true
          fi
        '';
      };

      # Write powerline theme
      home.activation.writePowerlineTheme = {
        after = [ "installPiMonty" ];
        before = [ ];
        data = ''
                    mkdir -p "${agentDir}/npm/node_modules/pi-powerline-footer"
                    cat > "${agentDir}/npm/node_modules/pi-powerline-footer/theme.json" << 'PLTHEME'
            ${powerlineTheme}
          PLTHEME
        '';
      };
    })
    dashboardConfig
  ];
}
