{
  config,
  lib,
  pkgs,
  aiDeepseek,
  aiXiaomi,
  aiCrofai,
  ...
}:
let
  cfg = config.dotfiles.ohMyPi;
  workModels = config.dotfiles.workModels;

  # Two-tier subagent hierarchy: a strong model drives the main session and the
  # deep-reasoning roles; a weak/cheap model handles everything that gets
  # routinely delegated. Subagent roles prefer the weak tier wherever reasonable
  # so cheap delegation happens as often as possible.
  strongModel =
    if workModels then
      "anthropic/claude-opus-4-8"
    else
      "${aiXiaomi.providerId}/${aiXiaomi.models.mimoV25Pro.id}";
  weakModel =
    if workModels then
      "anthropic/claude-sonnet-4-6"
    else
      "${aiXiaomi.providerId}/${aiXiaomi.models.mimoV25.id}";

  # Strong: main session + planning + review/oracle. Weak: general task agent,
  # scouts (smol/quick_task/explore/librarian), vision, designer, commit.
  modelRoles = {
    default = strongModel;
    plan = strongModel;
    slow = strongModel;
    task = weakModel;
    smol = weakModel;
    vision = weakModel;
    designer = weakModel;
    commit = weakModel;
  };

  # Provider priority: primary tier provider first, then backups for failover.
  modelProviderOrder =
    if workModels then
      [
        "anthropic"
        "openai-codex"
      ]
    else
      [
        aiXiaomi.providerId
        aiDeepseek.providerId
        aiCrofai.providerId
        "smortress"
      ]
      ++ lib.optionals cfg.claude.enable [ "anthropic" ]
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
          ${aiCrofai.providerId} = {
            baseUrl = aiCrofai.baseUrl;
            apiKey = "CROFAI_API_KEY";
            api = "openai-completions";
            auth = "apiKey";
            models = aiCrofai.ompModelsList;
          };
        };
      };

  ompConfig = {
    lastChangelogVersion = "15.5.11";
    inherit modelRoles;
    theme = {
      dark = "dark-gruvbox";
      light = "light-gruvbox";
    };
    display = {
      showTokenUsage = true;
      shimmer = "classic";
    };
    hideThinkingBlock = false;
    memory = {
      backend = "mnemopi";
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
    setupVersion = 1;
    extensions = [ ];
    disabledServers = [ "beads" ];
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
    read = {
      summarize = {
        prose = false;
      };
    };
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
    enable = lib.mkEnableOption "oh-my-pi token-efficient config" // {
      description = "Enable aggressive compaction, plugin installation, and tool-pinned abbreviation for omp.";
      default = true;
    };

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

    claude = {
      enable = lib.mkEnableOption "Anthropic Claude OAuth credentials for oh-my-pi";
    };
  };

  config = lib.mkIf cfg.enable {
    home.file.".omp/agent/config.yml".text = builtins.toJSON ompConfig + "\n";
    home.file.".omp/agent/models.yml".text = builtins.toJSON modelsConfig;

    home.activation.installOmpCli = {
      after = [ "linkGeneration" ];
      before = [ "installOmpPlugins" ];
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

    home.activation.installOmpPlugins = {
      after = [
        "linkGeneration"
        "installOmpCli"
      ];
      before = [ ];
      data = ''
        export PATH="$HOME/.bun/bin:$HOME/.cache/.bun/bin:$PATH"

        if ! command -v omp >/dev/null 2>&1; then
          echo "[oh-my-pi] omp not found in PATH, skipping plugin install"
        elif ! omp plugin list >/dev/null 2>&1; then
          echo "[oh-my-pi] omp is not runnable, skipping plugin install"
        else
          uninstall_plugin() {
            local name="$1"
            if omp plugin list 2>/dev/null | grep -q "$name"; then
              omp plugin uninstall "$name" 2>&1 || true
            fi
          }

          # omp is the minimal backup agent: agent config only, no plugins
          uninstall_plugin "pi-caveman"
          uninstall_plugin "pi-context-usage"
        fi
      '';
    };

    home.activation.configureOmpClaude = lib.mkIf cfg.claude.enable {
      after = [ "linkGeneration" ];
      before = [ ];
      data = ''
        export PATH="$HOME/.bun/bin:$HOME/.cache/.bun/bin:$PATH"

        if ! command -v omp >/dev/null 2>&1; then
          echo "[oh-my-pi] omp not found in PATH, skipping Claude OAuth import"
        else
          CREDENTIALS_FILE="$HOME/.claude/.credentials.json"
          if [ ! -r "$CREDENTIALS_FILE" ]; then
            echo "[oh-my-pi] No Claude credentials at $CREDENTIALS_FILE, skipping Claude OAuth import"
          elif ! ${pkgs.jq}/bin/jq -e '.claudeAiOauth.accessToken and .claudeAiOauth.refreshToken and .claudeAiOauth.expiresAt' "$CREDENTIALS_FILE" >/dev/null 2>&1; then
            echo "[oh-my-pi] Claude credentials are missing OAuth token fields, skipping Claude OAuth import"
          else
            should_import=1
            AGENT_DB="$HOME/.omp/agent/agent.db"
            if [ -r "$AGENT_DB" ]; then
              active_count="$(${pkgs.sqlite}/bin/sqlite3 "$AGENT_DB" "select count(*) from auth_credentials where provider = 'anthropic' and disabled_cause is null;" 2>/dev/null || echo 0)"
              case "$active_count" in
                0|"") ;;
                *)
                  echo "[oh-my-pi] Anthropic credentials already present, skipping Claude OAuth import"
                  should_import=0
                  ;;
              esac
            fi

            if [ "$should_import" = 1 ]; then
              tmp="$(${pkgs.coreutils}/bin/mktemp "''${TMPDIR:-/tmp}/omp-claude-auth.XXXXXX.json")"
              cleanup() {
                rm -f "$tmp"
              }
              trap cleanup EXIT

              ${pkgs.jq}/bin/jq '{
                type: "claude",
                access_token: .claudeAiOauth.accessToken,
                refresh_token: .claudeAiOauth.refreshToken,
                expired: (.claudeAiOauth.expiresAt / 1000 | floor | todateiso8601)
              }' "$CREDENTIALS_FILE" > "$tmp"
              chmod 600 "$tmp" 2>/dev/null || true

              if omp auth-broker import "$tmp" --provider anthropic >/dev/null 2>&1; then
                echo "[oh-my-pi] Claude OAuth credentials imported for Anthropic models"
              else
                echo "[oh-my-pi] Failed to import Claude OAuth credentials into OMP"
              fi
            fi
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

    programs.fish.shellAbbrs = {
      oc = "omp --tools read,edit,write,search,find,bash,lsp,todo_write,ask";
    };
  };
}
