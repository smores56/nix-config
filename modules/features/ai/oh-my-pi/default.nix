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

  modelProviderOrder =
    if workModels then
      [
        "openai-codex"
        "anthropic"
      ]
    else
      [
        "smortress"
        aiXiaomi.providerId
        "deepseek"
        aiCrofai.providerId
      ]
      ++ lib.optionals cfg.claude.enable [ "anthropic" ]
      ++ lib.optionals cfg.codex.enable [ "openai-codex" ];

  workRolesYaml = ''
    default: openai-codex/gpt-5.5-codex
    slow: anthropic/claude-opus-4-8
    plan: openai-codex/gpt-5.5-codex
    smol: openai-codex/gpt-5.5-codex
    vision: openai-codex/gpt-5.5-codex
    designer: openai-codex/gpt-5.5-codex
    commit: openai-codex/gpt-5.5-codex
    task: openai-codex/gpt-5.5-codex'';

  personalRolesYaml =
    lib.concatStringsSep "\n" (
      map (name: "  ${name}: ${aiXiaomi.roles.${name}}") [
        "default"
        "slow"
        "plan"
        "smol"
        "vision"
        "designer"
        "commit"
        "task"
      ]
    )
    + "\n  smol: smortress/gemma-4-31b\n  commit: smortress/gemma-4-31b";

  modelRolesYaml = if workModels then workRolesYaml else personalRolesYaml;

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

  ompPackage = "@oh-my-pi/pi-coding-agent";
  ompPrivateDir = "$HOME/.local/share/oh-my-pi-cli";
  ompPrivateEntrypoint = "${ompPrivateDir}/node_modules/${ompPackage}/src/cli.ts";
  ompLegacyEntrypoint = "$HOME/.bun/install/global/node_modules/${ompPackage}/src/cli.ts";
  ompEarendilEntrypoint = "$HOME/.bun/install/global/node_modules/@earendil-works/pi-coding-agent/src/cli.ts";
  ompWrapper = pkgs.writeShellScriptBin "omp" ''
    set -euo pipefail

    export PATH="$HOME/.bun/bin:$HOME/.cache/.bun/bin:$PATH"

    if [ -z "''${OPENAI_CODEX_OAUTH_TOKEN:-}" ] && [ -r "$HOME/.codex/auth.json" ]; then
      token="$(${pkgs.jq}/bin/jq -r '.tokens.access_token // empty' "$HOME/.codex/auth.json" 2>/dev/null || true)"
      if [ -n "$token" ] && [ "$token" != "null" ]; then
        export OPENAI_CODEX_OAUTH_TOKEN="$token"
      fi
    fi

    if [ -z "''${ANTHROPIC_OAUTH_TOKEN:-}" ] && [ -r "$HOME/.claude/.credentials.json" ]; then
      token="$(${pkgs.jq}/bin/jq -r '.claudeAiOauth.accessToken // empty' "$HOME/.claude/.credentials.json" 2>/dev/null || true)"
      if [ -n "$token" ] && [ "$token" != "null" ]; then
        export ANTHROPIC_OAUTH_TOKEN="$token"
      fi
    fi

    for entrypoint in "${ompPrivateEntrypoint}" "${ompLegacyEntrypoint}" "${ompEarendilEntrypoint}"; do
      if [ -r "$entrypoint" ]; then
        exec "$HOME/.bun/bin/bun" "$entrypoint" "$@"
      fi
    done

    echo "oh-my-pi CLI not installed. Re-run home-manager switch, or install ${ompPackage} into ${ompPrivateDir}." >&2
    exit 127

  '';
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
    home.file.".omp/agent/config.yml".text = ''
      lastChangelogVersion: 15.5.11
      modelRoles:
      ${modelRolesYaml}
      theme:
        dark: dark-gruvbox
        light: light-gruvbox
      display:
        showTokenUsage: true
        shimmer: classic
      hideThinkingBlock: false
      memory:
        backend: mnemopi
      exa:
        enableResearcher: false
      compaction:
        keepRecentTokens: ${toString cfg.compaction.keepRecentTokens}
        enabled: true
        reserveTokens: ${toString cfg.compaction.reserveTokens}
        autoContinue: ${lib.boolToString cfg.compaction.autoContinue}
        handoffSaveToDisk: true
      steeringMode: one-at-a-time
      setupVersion: 1
      extensions: []
      disabledServers:
        - beads
      tools:
        discoveryMode: all
      modelProviderOrder: ${builtins.toJSON modelProviderOrder}
      symbolPreset: nerd
      task:
        showResolvedModelBadge: true
        isolation:
          mode: auto
        eager: true
      stt:
        enabled: true
      collapseChangelog: true
      tui:
        textSizing: true
      readLineNumbers: true
      read:
        summarize:
          prose: false
      lsp:
        formatOnWrite: true
        diagnosticsOnEdit: true
      bashInterceptor:
        enabled: true
      renderMermaid:
        enabled: true
      checkpoint:
        enabled: true
      github:
        enabled: true
      async:
        enabled: true
      bash:
        autoBackground:
          enabled: true
      mcp:
        discoveryMode: true
      secrets:
        enabled: true
    '';
    home.file.".omp/agent/models.yml".text = builtins.toJSON modelsConfig;
    home.packages = [ ompWrapper ];

    home.file.".local/bin/omp" = {
      source = "${ompWrapper}/bin/omp";
    };

    home.file.".bun/bin/omp" = {
      force = true;
      source = "${ompWrapper}/bin/omp";
    };

    home.activation.installOmpCli = {
      after = [ "linkGeneration" ];
      before = [ "installOmpPlugins" ];
      data = ''
        export PATH="$HOME/.bun/bin:$HOME/.cache/.bun/bin:$PATH"
        CLI_DIR="${ompPrivateDir}"
        ENTRYPOINT="${ompPrivateEntrypoint}"

        if [ -r "$ENTRYPOINT" ]; then
          echo "[oh-my-pi] OMP CLI already installed"
        elif ! command -v bun >/dev/null 2>&1; then
          echo "[oh-my-pi] bun not found in PATH, cannot install ${ompPackage}" >&2
        else
          echo "[oh-my-pi] Installing ${ompPackage} into $CLI_DIR"
          mkdir -p "$CLI_DIR"
          printf '%s\n' '{"private":true,"dependencies":{"${ompPackage}":"latest"}}' > "$CLI_DIR/package.json"
          if ! (
            cd "$CLI_DIR"
            bun install
          ); then
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
          install_plugin() {
            local name="$1"
            if ! omp plugin list 2>/dev/null | grep -q "$name"; then
              omp plugin install "$name" 2>&1 || true
            fi
          }

          uninstall_plugin() {
            local name="$1"
            if omp plugin list 2>/dev/null | grep -q "$name"; then
              omp plugin uninstall "$name" 2>&1 || true
            fi
          }

          install_plugin "pi-caveman"
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

    home.file.".omp/agent/extensions/plan-mode.ts".source = ./plan-mode.ts;
    programs.fish.shellAbbrs = {
      oc = "omp --tools read,edit,write,search,find,bash,lsp,todo_write,ask";
    };
  };
}
