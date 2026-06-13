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

  # Pinned pi-agent-hub fork (smores56/pi-agent-hub). dist/ is vendored at this
  # commit so bun installs it directly (git deps skip build scripts); both the
  # pi-hub CLI and the hub extension come from this install. Bump after pushing
  # a new built commit, then `home-manager switch`.
  piAgentHubRev = "d930f98a362e215c57c8a683f86986a4417ce76d";

  # Extension stack. Decision record + conflict map: ./EXTENSIONS.md
  piPackages = [
    # Orchestration
    "npm:pi-subagents" # curated subagents, chains/parallel, acceptance contracts
    "npm:pi-agent-hub" # standalone pi-hub TUI: spawns/manages real pi sessions in tmux
    "npm:pi-intercom" # child->parent comms for pi-subagents
    # Core capability
    "npm:@sherif-fanous/pi-rtk" # bash->rtk rewriting (sole bash tool owner)
    "npm:pi-hermes-memory" # policy-only memory + session search + secret scanning
    "npm:pi-web-access" # required by the researcher builtin
    "npm:pi-mcp-adapter"
    "npm:pi-vision-proxy"
    # UX
    "npm:pi-lsp-lite" # same-turn diagnostics on write/edit; lazy server spawn
    "npm:@wierdbytes/pi-statusline" # footer; renders extension statuses + subagent chips
    "npm:pi-animations" # working-indicator animations (1-line modes safe with statusline)
    "npm:@thinkscape/pi-status" # terminal title + Ghostty native progress bar
    "npm:@juicesharp/rpiv-ask-user-question" # structured questions w/ previews
    "npm:@juicesharp/rpiv-todo"
    "npm:@juicesharp/rpiv-btw"
    "npm:pi-rewind" # yolo-mode undo (use /rewind; Esc+Esc stays "tree")
    "npm:pi-notify"
    # Workflow carryovers
    "npm:pi-autoresearch"
    "npm:pi-review-loop"
    # Round 2 (see EXTENSIONS.md "Round 2")
    "npm:pi-background-tasks" # bg_run/status/logs/kill, rtk-safe, headless-safe
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
  strongModel = if workModels then "anthropic/claude-opus-4-8" else cfg.defaultModel;
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
  # auto-learning stays cheap (incl. inside pi-hub worker sessions).
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
  # Token setup helper for the Slack MCP server (see slack-mcp-auth.sh).
  slackMcpAuth = pkgs.writeShellScriptBin "slack-mcp-auth" (builtins.readFile ./slack-mcp-auth.sh);
in
{
  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      home = {
        packages = lib.mkIf (cfg.mcpServers ? slack) [ slackMcpAuth ];

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
              editorPaddingX = 2; # breathing room - no typing on the bare terminal edge
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

          # MCP servers for pi-mcp-adapter. Pi-only scope: the agent-dir file
          # isn't picked up by other MCP hosts (unlike ~/.config/mcp/mcp.json).
          # Adapter-side overrides from /mcp get clobbered on next switch.
          "${agentDir}/mcp.json" = lib.mkIf (cfg.mcpServers != { }) {
            force = true;
            text = builtins.toJSON { mcpServers = cfg.mcpServers; };
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
          "${agentDir}/extensions/plan-mode.ts".source = ./extensions/plan-mode.ts;
          "${agentDir}/extensions/code-execution.ts".source = ./extensions/code-execution.ts;
          "${agentDir}/extensions/splash.ts".source = ./extensions/splash.ts;
          "${agentDir}/APPEND_SYSTEM.md".source = ./APPEND_SYSTEM.md;

          "${homeDir}/.config/fish/conf.d/pi-aliases.fish".text = ''
            # pi packages' CLI binaries (pi-hub etc.)
            fish_add_path --append ${npmDir}/node_modules/.bin

            function p --wraps 'pi' --description 'p: pi'
              FISH_TERMINAL_SKIP_DSR=1 pi $argv
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

          # Install the pinned pi-agent-hub fork from git into the agent npm
          # dir, providing both the pi-hub CLI and the hub extension. Runs
          # before installPiPackages so its npm:pi-agent-hub entry is treated as
          # already satisfied (the dir exists) and not pulled from the registry.
          installPiAgentHubFork = {
            after = [ "installPiCli" ];
            before = [ "installPiPackages" ];
            data = ''
              NPM_DIR="${npmDir}"
              REV="${piAgentHubRev}"
              MARKER="$NPM_DIR/.pi-agent-hub-rev"
              # bun shells out to git/ssh to clone the git dep; the activation
              # PATH is minimal, so provide them explicitly. SSH key selection
              # comes from the user's git core.sshCommand (absolute store path).
              export PATH="${pkgs.git}/bin:${pkgs.openssh}/bin:$PATH"
              mkdir -p "$NPM_DIR"
              if ! command -v "${bunBin}/bun" >/dev/null 2>&1; then
                echo "[pi] bun not found; cannot install pi-agent-hub fork" >&2
              elif [ "$(cat "$MARKER" 2>/dev/null)" = "$REV" ] && [ -d "$NPM_DIR/node_modules/pi-agent-hub" ]; then
                echo "[pi] pi-agent-hub fork already at $REV"
              else
                echo "[pi] Installing pi-agent-hub fork @ $REV"
                rm -rf "$NPM_DIR/node_modules/pi-agent-hub" "$NPM_DIR/node_modules/pi-agent-hub.npm-backup"
                # Clear any prior registry entry so the git spec does not
                # collide with a leftover pi-agent-hub@^x (bun DependencyLoop).
                (cd "$NPM_DIR" && "${bunBin}/bun" remove pi-agent-hub 2>/dev/null) || true
                if (cd "$NPM_DIR" && "${bunBin}/bun" add "git+ssh://git@github.com/smores56/pi-agent-hub.git#$REV" 2>&1); then
                  printf '%s\n' "$REV" > "$MARKER"
                else
                  echo "[pi] Failed to install pi-agent-hub fork" >&2
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
              for STALE in pi-total-recall pi-rtk-optimizer pi-powerline-footer pi-pokepet pi-emote pi-bar @codesook/pi-welcome-screen pi-lens pisesh pi-agent-board; do
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
                '') (builtins.filter (source: source != "npm:pi-agent-hub") piPackages)
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
                    workingAnim = "neural-pulse";
                    thinkingAnim = "typewriter";
                    toolAnim = "neon-bounce";
                    width = "full";
                    randomMode = false;
                    enabled = true;
                  }
                }' > "$ANIM_CFG"
              fi
            '';
          };

          # pi-lsp-lite imports vscode-languageserver-protocol/node.js, but bun
          # resolves protocol 3.18 (satisfies ^3.17.5) whose exports map only has
          # ./node - extension fails to load. Patch the subpath. No-ops once
          # applied or when upstream fixes the import/pins the dep.
          patchPiLspLiteImport = {
            after = [ "installPiPackages" ];
            before = [ ];
            data = ''
              LSPC="${npmDir}/node_modules/pi-lsp-lite/src/client.ts"
              if [ -f "$LSPC" ]; then
                ${pkgs.perl}/bin/perl -pi -e 's{from "vscode-languageserver-protocol/node\.js"}{from "vscode-languageserver-protocol/node"}' "$LSPC" || true
              fi
            '';
          };

          # pi-animations restores pi's default "Working..." text at agent_end
          # and session_switch, which flashes for a beat while the loader row is
          # still visible. Blank it instead (/animation off keeps the default).
          patchPiAnimationsEndFlash = {
            after = [ "installPiPackages" ];
            before = [ ];
            data = ''
              ANIM="${npmDir}/node_modules/pi-animations/animations.ts"
              if [ -f "$ANIM" ]; then
                ${pkgs.perl}/bin/perl -0777 -pi -e 's/(stopThinkingTicker\(\);\n\t\tctx\.ui\.setWorkingMessage\()\); \/\/ restore default/$1""); \/\/ blank, not default "Working..." - avoids end-of-turn flash/' "$ANIM" || true
                ${pkgs.perl}/bin/perl -0777 -pi -e 's/("session_switch", async \(_e, ctx\) => \{\n\t\tstopWorkingAnimation\(ctx\);\n\t\tstopThinkingTicker\(\);\n\t\tctx\.ui\.setWorkingMessage\()\)/$1"")/' "$ANIM" || true
              fi
            '';
          };

          # pi-statusline replaces pi's editor with its own component that
          # hardcodes PROMPT_PADDING = 0 and overrides setPaddingX to ignore the
          # editorPaddingX setting. Patch the constant to 2, then overdraw the
          # first line's two padding spaces with a periwinkle ❯ (U+276F) +
          # space - same visual width, so cursor math stays correct.
          # Both substitutions are idempotent.
          patchPiStatuslinePrompt = {
            after = [ "installPiPackages" ];
            before = [ ];
            data = ''
              SL="${npmDir}/node_modules/@wierdbytes/pi-statusline/index.ts"
              if [ -f "$SL" ]; then
                ${pkgs.perl}/bin/perl -pi -e 's/const PROMPT_PADDING = 0;/const PROMPT_PADDING = 2;/' "$SL" || true
                ${pkgs.perl}/bin/perl -0777 -pi -e 's/(            break;\n          \}\n        \}\n)\n        return lines;/$1\n        if (lines.length > 0 \&\& lines[0].startsWith("  ")) {\n          lines[0] = "\\x1b[38;2;153;142;241m\xe2\x9d\xaf\\x1b[39m " + lines[0].slice(2);\n        }\n\n        return lines;/' "$SL" || true
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
