{
  config,
  lib,
  pkgs,
  aiDeepseek,
  aiXiaomi,
  aiNeuralwatt,
  ...
}:
let
  cfg = config.dotfiles.ohMyPi;
  workModels = config.dotfiles.workModels;

  # Three-tier subagent hierarchy. Work: Codex-only via the built-in openai-codex
  # provider — smart gpt-5.5 (main session + deep-reasoning roles), middle gpt-5.4
  # (general task agent), dumb gpt-5.4-mini (scouts/vision/designer/commit).
  # Personal: Neuralwatt GLM-5.2 / Qwen3.5-397B / Qwen3.6-35B. Delegation prefers the cheaper tiers.
  strongModel =
    if workModels then
      "openai-codex/gpt-5.5"
    else
      "${aiNeuralwatt.providerId}/${aiNeuralwatt.models.glm52.id}";
  midModel =
    if workModels then
      "openai-codex/gpt-5.4"
    else
      "${aiNeuralwatt.providerId}/${aiNeuralwatt.models.qwen35.id}";
  weakModel =
    if workModels then
      "openai-codex/gpt-5.4-mini"
    else
      "${aiNeuralwatt.providerId}/${aiNeuralwatt.models.qwen36.id}";

  # Smart: main session + planning + slow/deep reasoning. Middle: general task
  # agent. Dumb: scouts (smol), vision, designer, commit.
  modelRoles = {
    default = strongModel;
    plan = strongModel;
    slow = strongModel;
    task = midModel;
    smol = weakModel;
    vision = weakModel;
    designer = weakModel;
    commit = weakModel;
  };

  # Provider priority: primary tier provider first, then backups for failover.
  modelProviderOrder =
    if workModels then
      [ "openai-codex" ]
    else
      [
        aiNeuralwatt.providerId
        aiXiaomi.providerId
        aiDeepseek.providerId
        "smortress"
      ]
      ++ lib.optionals cfg.codex.enable [ "openai-codex" ];

  modelsConfig =
    if workModels then
      { }
    else
      {
        providers = {
          ${aiXiaomi.providerId} = {
            baseUrl = aiXiaomi.baseUrl;
            apiKey = "XIAOMI_MIMO_API_KEY";
            api = "openai-completions";
            auth = "apiKey";
            models = aiXiaomi.ompModelsList;
          };
          smortress = {
            baseUrl = "http://smortress:8081/v1";
            api = "openai-completions";
            auth = "none";
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
                compat = {
                  supportsDeveloperRole = false;
                };
              }
            ];
          };
          ${aiDeepseek.providerId} = {
            baseUrl = aiDeepseek.baseUrl;
            apiKey = "DEEPSEEK_API_KEY";
            api = "openai-completions";
            auth = "apiKey";
            models = aiDeepseek.ompModelsList;
          };
          ${aiNeuralwatt.providerId} = {
            baseUrl = aiNeuralwatt.baseUrl;
            apiKey = "NEURALWATT_API_KEY";
            api = "openai-completions";
            auth = "apiKey";
            models = aiNeuralwatt.ompModelsList;
          };
        };
      };

  ompConfig = {
    inherit modelRoles;
    display = {
      showTokenUsage = true;
      shimmer = "classic";
    };
    hideThinkingBlock = false;
    memory = {
      backend = "mnemopi";
    };
    mnemopi = {
      llmMode = "none";
    };
    exa = {
      enableResearcher = false;
    };
    compaction = {
      keepRecentTokens = cfg.compaction.keepRecentTokens;
      enabled = true;
      reserveTokens = cfg.compaction.reserveTokens;
      autoContinue = cfg.compaction.autoContinue;
      handoffSaveToDisk = true;
    };
    steeringMode = "one-at-a-time";
    tools = {
      discoveryMode = "all";
    };
    inherit modelProviderOrder;
    symbolPreset = "nerd";
    task = {
      showResolvedModelBadge = true;
      isolation = {
        mode = "auto";
      };
      eager = true;
    };
    stt = {
      enabled = true;
    };
    collapseChangelog = true;
    tui = {
      textSizing = true;
    };
    readLineNumbers = true;
    lsp = {
      formatOnWrite = true;
      diagnosticsOnEdit = true;
    };
    bashInterceptor = {
      enabled = true;
    };
    renderMermaid = {
      enabled = true;
    };
    checkpoint = {
      enabled = true;
    };
    github = {
      enabled = true;
    };
    async = {
      enabled = true;
    };
    bash = {
      autoBackground = {
        enabled = true;
      };
    };
    mcp = {
      discoveryMode = true;
    };
    secrets = {
      enabled = true;
    };
  };

  ompPackage = "@oh-my-pi/pi-coding-agent";
in
{
  options.dotfiles.ohMyPi = {
    compaction = {
      reserveTokens = lib.mkOption {
        type = lib.types.int;
        default = 32768;
        description = "Token budget reserved for agent output after compaction.";
      };
      keepRecentTokens = lib.mkOption {
        type = lib.types.int;
        default = 48000;
        description = "Number of recent tokens preserved during compaction.";
      };
      autoContinue = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Automatically continue after compaction instead of prompting.";
      };
    };

    codex = {
      enable = lib.mkEnableOption "OpenAI Codex OAuth credentials for oh-my-pi";
    };

    mcpServers = lib.mkOption {
      type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything);
      default = { };
      description = ''
        MCP server definitions written to ~/.omp/agent/mcp.json. Standard
        mcp.json schema (command/args/env or url/headers). Values may reference
        secrets via ''${ENV_VAR} interpolation, resolved by oh-my-pi at runtime
        so tokens stay out of the Nix store.
      '';
    };
  };

  config = {
    # `config.yml` is omp-owned and mutable (so omp's Settings writer —
    # settings.ts:#saveNow, which reads-modifies-writes via Bun.write + YAML
    # stringify on every in-app setting toggle — actually works, instead of
    # hitting /nix/store EROFS on a symlink). Nix still *enforces* its
    # declared `ompConfig` keys every activation via a `yq` deep-merge
    # (`. * $nix`): Nix-declared values win, omp/runtime-only keys survive.
    # Edit at runtime with `yq` (YAML-native jq, added to home.packages
    # below) — `jq` breaks once omp rewrites the file as YAML.
    home.file.".omp/agent/models.yml".text = builtins.toJSON modelsConfig;
    home.file.".omp/agent/mcp.json" = lib.mkIf (cfg.mcpServers != { }) {
      force = true;
      text = builtins.toJSON { mcpServers = cfg.mcpServers; };
    };

    home.activation.enforceOmpConfig = {
      after = [ "linkGeneration" ];
      before = [ "installOmpCli" ];
      data =
        let
          ompConfigJson = builtins.toJSON ompConfig;
          nixConfigYaml = pkgs.writeText "omp-config-nix.yml" ompConfigJson;
        in
        ''
          export PATH="${pkgs.yq}/bin:$PATH"
          CONFIG="$HOME/.omp/agent/config.yml"
          NIX_CONFIG="${nixConfigYaml}"

          mkdir -p "$(dirname "$CONFIG")"

          # If config.yml is missing or still a Nix-managed symlink into the
          # store, seed it fresh from the Nix-declared config. From here on omp
          # owns the real file.
          if [ ! -e "$CONFIG" ] || [ -L "$CONFIG" ]; then
            echo "[oh-my-pi] Seeding $CONFIG from Nix"
            rm -f "$CONFIG"
            yq -y '.' "$NIX_CONFIG" > "$CONFIG"
            exit 0
          fi

          # Otherwise: omp already owns the file. Deep-merge the Nix-declared
          # config on top so declared keys are re-enforced on every switch,
          # while runtime-only keys (auth tokens captured at runtime, etc.)
          # survive. `. * $nix` is a shallow-on-arrays / deep-on-objects merge:
          # an array value in Nix replaces the runtime array (intentional —
          # e.g. `disabledServers`, `extensions`), object values merge recursively.
          echo "[oh-my-pi] Re-enforcing Nix-declared config onto $CONFIG"
          tmp="$(mktemp "''${TMPDIR:-/tmp}/omp-config.XXXXXX.yml")"
          if yq -y --slurpfile nix "$NIX_CONFIG" '. * $nix[0]' "$CONFIG" > "$tmp"; then
            mv -f "$tmp" "$CONFIG"
          else
            echo "[oh-my-pi] yq merge failed, leaving $CONFIG untouched" >&2
            rm -f "$tmp"
          fi
        '';
    };

    # `spawn_session` omp tool, mirroring maki's lua tool
    # (modules/features/ai/maki/lua/spawn_session.lua) on omp's native
    # extension surface. omp auto-loads ~/.omp/agent/extensions/<dir>/index.ts,
    # and ompConfig's `tools.discoveryMode = "all"` force-includes the tool —
    # no build/bun install step (imports resolve against omp's host bundle).
    home.file.".omp/agent/extensions/spawn_session/index.ts" = {
      force = true;
      source = ./extensions/spawn_session/index.ts;
    };

    home.activation.installOmpCli = {
      after = [ "linkGeneration" ];
      before = [ ];
      data = ''
        export PATH="$HOME/.bun/bin:$HOME/.cache/.bun/bin:$PATH"

        if command -v omp >/dev/null 2>&1; then
          echo "[oh-my-pi] omp already installed"
        elif ! command -v bun >/dev/null 2>&1; then
          echo "[oh-my-pi] bun not found in PATH, cannot install ${ompPackage}" >&2
        else
          echo "[oh-my-pi] Installing ${ompPackage} globally with bun"
          if ! bun add -g ${ompPackage}; then
            echo "[oh-my-pi] Failed to install ${ompPackage}; OMP plugin/config commands will be skipped" >&2
          fi
        fi
      '';
    };

    home.activation.configureOmpCodex = lib.mkIf cfg.codex.enable {
      after = [ "linkGeneration" ];
      before = [ ];
      data = ''
        export PATH="$HOME/.bun/bin:$HOME/.cache/.bun/bin:$PATH"

        if ! command -v omp >/dev/null 2>&1; then
          echo "[oh-my-pi] omp not found in PATH, skipping Codex OAuth import"
        else
          AUTH_FILE="$HOME/.codex/auth.json"
          if [ ! -r "$AUTH_FILE" ]; then
            echo "[oh-my-pi] No Codex credentials at $AUTH_FILE, skipping Codex OAuth import"
          elif ! ${pkgs.jq}/bin/jq -e '.tokens.access_token and .tokens.refresh_token' "$AUTH_FILE" >/dev/null 2>&1; then
            echo "[oh-my-pi] Codex credentials are missing OAuth token fields, skipping Codex OAuth import"
          else
            should_import=1
            AGENT_DB="$HOME/.omp/agent/agent.db"
            if [ -r "$AGENT_DB" ]; then
              active_count="$(${pkgs.sqlite}/bin/sqlite3 "$AGENT_DB" "select count(*) from auth_credentials where provider = 'openai-codex' and disabled_cause is null;" 2>/dev/null || echo 0)"
              case "$active_count" in
                0|"") ;;
                *)
                  echo "[oh-my-pi] Codex credentials already present, skipping Codex OAuth import"
                  should_import=0
                  ;;
              esac
            fi

            if [ "$should_import" = 1 ]; then
              expired="$(${pkgs.jq}/bin/jq -r '.tokens.access_token | split(".")[1] | gsub("-";"+") | gsub("_";"/") | @base64d | fromjson | .exp | todateiso8601' "$AUTH_FILE" 2>/dev/null || true)"
              if [ -z "$expired" ]; then
                echo "[oh-my-pi] Could not derive Codex token expiry, skipping Codex OAuth import" >&2
              else
                tmp="$(${pkgs.coreutils}/bin/mktemp "''${TMPDIR:-/tmp}/omp-codex-auth.XXXXXX.json")"
                cleanup() {
                  rm -f "$tmp"
                }
                trap cleanup EXIT

                ${pkgs.jq}/bin/jq --arg expired "$expired" '{
                  type: "openai-codex",
                  access_token: .tokens.access_token,
                  refresh_token: .tokens.refresh_token,
                  account_id: .tokens.account_id,
                  expired: $expired
                }' "$AUTH_FILE" > "$tmp"
                chmod 600 "$tmp" 2>/dev/null || true

                if omp auth-broker import "$tmp" --provider openai-codex >/dev/null 2>&1; then
                  echo "[oh-my-pi] Codex OAuth credentials imported for openai-codex models"
                else
                  echo "[oh-my-pi] Failed to import Codex OAuth credentials into OMP"
                fi
              fi
            fi
          fi
        fi
      '';
    };

    home.packages = [ pkgs.yq ];
  };
}
