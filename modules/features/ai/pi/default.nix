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

  # Extension stack. Decision record + conflict map: ./EXTENSIONS.md
  piPackages = [
    # Orchestration
    "npm:pi-subagents" # curated subagents, chains/parallel, acceptance contracts
    "npm:pi-agent-board" # agent-view: dispatch/monitor/attach background pi sessions
    "npm:pi-intercom" # child->parent comms for pi-subagents
    # Core capability
    "npm:@sherif-fanous/pi-rtk" # bash->rtk rewriting (sole bash tool owner)
    "npm:pi-hermes-memory" # policy-only memory + session search + secret scanning
    "npm:pi-web-access" # required by the researcher builtin
    "npm:pi-mcp-adapter"
    "npm:pi-vision-proxy"
    # UX
    "npm:@wierdbytes/pi-statusline" # footer; renders extension statuses + subagent chips
    "npm:pi-animations" # working-indicator animations (1-line modes safe with statusline)
    "npm:@thinkscape/pi-status" # terminal title + Ghostty native progress bar
    "npm:@juicesharp/rpiv-ask-user-question" # structured questions w/ previews
    "npm:@juicesharp/rpiv-todo"
    "npm:@juicesharp/rpiv-btw"
    "npm:pi-rewind" # yolo-mode undo (use /rewind; Esc+Esc stays "tree")
    "npm:pi-lens" # LSP/lint feedback to agent
    "npm:pi-notify"
    # Workflow carryovers
    "npm:pi-autoresearch"
    "npm:pi-review-loop"
    # Round 2 (see EXTENSIONS.md "Round 2")
    "npm:pi-background-tasks" # bg_run/status/logs/kill, rtk-safe, headless-safe
    "npm:pisesh" # session browse/favorites/resume TUI, zero LLM cost
    "npm:pi-autoname" # light auto-naming on weak tier; /autoname for manual (MIT, source in tarball, no public repo)
    "npm:pi-tool-display" # display-only tool rendering, RTK-aware hints
    "npm:@agnishc/edb-agent-steer" # mid-turn Enter -> steer/queue/discard/edit menu
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

  # Providers available regardless of workModels; the conditional providers
  # below add the per-context primary tier on top.
  commonProviders = {
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
      inherit (aiDeepseek) baseUrl;
      apiKey = "$DEEPSEEK_API_KEY";
      api = "openai-completions";
      models = aiDeepseek.ompModelsList;
    };
    ${aiCrofai.providerId} = {
      inherit (aiCrofai) baseUrl;
      apiKey = "$CROFAI_API_KEY";
      api = "openai-completions";
      models = aiCrofai.ompModelsList;
    };
  };

  workProviders = {
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
  };

  personalProviders = {
    ${aiXiaomi.providerId} = {
      inherit (aiXiaomi) baseUrl;
      apiKey = "$XIAOMI_MIMO_API_KEY";
      api = "openai-completions";
      models = aiXiaomi.ompModelsList;
    };
  };

  modelsConfig = {
    providers = commonProviders // (if workModels then workProviders else personalProviders);
  };

  # pi-autoname: first-dialogue + periodic session naming on the weak tier.
  # respectManualName keeps /name sticky; text-extraction fallback if AI fails.
  autonameConfig = builtins.toJSON {
    enabled = true;
    model = weakModel;
    fallbackModels = weakBackups;
    cooldownMinutes = 30;
    respectManualName = true;
  };

  # pi-hermes-memory: policy-only injection (~200-500 tokens/turn, content
  # retrieved on demand), background reviews routed to the weak tier so
  # auto-learning stays cheap (incl. inside headless agent-board workers).
  hermesMemoryConfig = builtins.toJSON {
    memoryMode = "policy-only";
    memoryPolicyStyle = "compact";
    llmModelOverride = weakModel;
    llmThinkingOverride = "off";
    memoryOverflowStrategy = "auto-consolidate";
    autoConsolidate = true;
    correctionDetection = true;
    flushOnCompact = true;
    flushOnShutdown = true;
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
      home = {
        file = {
          "${agentDir}/settings.json" = {
            force = true;
            text = builtins.toJSON {
              inherit (cfg) defaultProvider defaultModel defaultThinkingLevel;
              theme = "noctis-uva";
              enableInstallTelemetry = false;
              quietStartup = true;
              collapseChangelog = true;
              # OAuth subscription billing notice on every session start – known, noisy
              warnings.anthropicExtraUsage = false;
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

          "${agentDir}/models.json" = {
            force = true;
            text = builtins.toJSON modelsConfig;
          };

          "${agentDir}/hermes-memory-config.json" = {
            force = true;
            text = hermesMemoryConfig;
          };

          "${agentDir}/pi-autoname.json" = {
            force = true;
            text = autonameConfig;
          };

          # Skills, themes, custom extensions, global rules
          "${agentDir}/skills/grill-me/SKILL.md".source = ./skills/grill-me/SKILL.md;
          "${agentDir}/themes/noctis-uva.json".source = ./themes/noctis-uva.json;
          "${agentDir}/extensions/plan-mode.ts".source = ../oh-my-pi/plan-mode.ts;
          "${agentDir}/extensions/code-execution.ts".source = ./extensions/code-execution.ts;
          "${agentDir}/extensions/splash.ts".source = ./extensions/splash.ts;
          "${agentDir}/APPEND_SYSTEM.md".source = ./APPEND_SYSTEM.md;

          "${homeDir}/.config/fish/conf.d/pi-aliases.fish".text = ''
            # pi-agent-board row summaries on the weak tier ("off" disables)
            set -gx AGENT_BOARD_SUMMARY_MODEL ${weakModel}

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
        };

        activation = {
          installPiCli = {
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
          installPiPackages = {
            after = [ "linkGeneration" ];
            before = [ "installPiMonty" ];
            data = ''
              NPM_DIR="${npmDir}"
              mkdir -p "$NPM_DIR"
              # Replaced by the June 2026 stack review (see EXTENSIONS.md)
              for STALE in pi-total-recall pi-rtk-optimizer pi-powerline-footer pi-pokepet pi-emote pi-bar @codesook/pi-welcome-screen; do
                if [ -d "$NPM_DIR/node_modules/$STALE" ]; then
                  echo "[pi] Removing replaced package $STALE"
                  (cd "$NPM_DIR" && "${bunBin}/bun" remove "$STALE" 2>&1) || true
                fi
              done
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
          # Seed pi-animations defaults (1-line animations only - multi-line
          # ones fight pi-statusline for above-editor space). Seed-if-missing so
          # /animation changes persist; delete the file to re-seed.
          seedPiAnimations = {
            after = [ "writeBoundary" ];
            before = [ ];
            data = ''
              ANIM_CFG="$HOME/.pi/agent/extensions/pi-tui-animations.json"
              if [ ! -f "$ANIM_CFG" ]; then
                mkdir -p "$(dirname "$ANIM_CFG")"
                printf '%s' '${
                  builtins.toJSON {
                    workingAnim = "pacman";
                    thinkingAnim = "plasma-wave";
                    toolAnim = "pipeline";
                    width = "full";
                    randomMode = false;
                    enabled = true;
                  }
                }' > "$ANIM_CFG"
              fi
            '';
          };

          # pi-agent-board hardcodes a Tailwind slate/sky palette in its
          # dashboard chrome (no theme hook). Remap those exact RGB triplets to
          # noctis-uva. Idempotent: no-ops once applied or if upstream changes.
          themePiAgentBoard = {
            after = [ "installPiPackages" ];
            before = [ ];
            data = ''
              BOARD="${npmDir}/node_modules/pi-agent-board/src"
              if [ -d "$BOARD" ]; then
                ${pkgs.findutils}/bin/find "$BOARD" -name '*.ts' -print0 | ${pkgs.findutils}/bin/xargs -0 ${pkgs.perl}/bin/perl -pi -e '
                  s/ansiFg\(248, 250, 252/ansiFg(224, 222, 238/g;  # slate-50  -> uva bright fg
                  s/ansiFg\(226, 232, 240/ansiFg(197, 194, 214/g;  # slate-200 -> fg
                  s/ansiFg\(148, 163, 184/ansiFg(141, 136, 174/g;  # slate-400 -> fgMuted
                  s/ansiFg\(100, 116, 139/ansiFg(92, 89, 115/g;    # slate-500 -> fgDim
                  s/ansiFg\(51, 65, 85/ansiFg(58, 54, 84/g;        # slate-700 -> borderMuted
                  s/ansiFg\(56, 189, 248/ansiFg(153, 142, 241/g;   # sky-400   -> periwinkle
                  s/ansiBg\(56, 189, 248/ansiBg(153, 142, 241/g;   # sky badge -> periwinkle
                  s/ansiFg\(15, 23, 42/ansiFg(41, 38, 64/g;        # slate-900 text -> uva bg
                  s/ansiBg\(15, 23, 42/ansiBg(41, 38, 64/g;        # slate-900 bg   -> uva bg
                  s/ansiBg\(30, 41, 59/ansiBg(52, 48, 82/g;        # slate-800 -> bgLight
                  # STAGE_RGB per-state row colors
                  s/queued: \[148, 163, 184\]/queued: [141, 136, 174]/;      # -> fgMuted
                  s/working: \[56, 189, 248\]/working: [73, 172, 233]/;      # -> uva blue
                  s/needs_input: \[245, 158, 11\]/needs_input: [230, 149, 51]/; # -> warnOrange
                  s/idle: \[129, 140, 248\]/idle: [153, 142, 241]/;          # -> periwinkle
                  s/completed: \[34, 197, 94\]/completed: [73, 233, 166]/;   # -> uva green
                  s/failed: \[248, 113, 113\]/failed: [227, 78, 28]/;        # -> errorRed
                  s/stopped: \[100, 116, 139\]/stopped: [92, 89, 115]/;      # -> fgDim
                ' || true
              fi
            '';
          };
          installPiMonty = {
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
        };
      };
    })
    dashboardConfig
  ];
}
