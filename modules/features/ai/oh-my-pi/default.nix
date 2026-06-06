{
  config,
  lib,
  pkgs,
  aiCrofai,
  ...
}:
let
  cfg = config.dotfiles.ohMyPi;
  modelProviderOrder = [
    "smortress"
    aiCrofai.providerId
  ]
  ++ lib.optionals cfg.claude.enable [ "anthropic" ]
  ++ lib.optionals cfg.codex.enable [ "openai-codex" ];
  ompPackage = "@oh-my-pi/pi-coding-agent";
  ompPrivateDir = "$HOME/.local/share/oh-my-pi-cli";
  ompPrivateEntrypoint = "${ompPrivateDir}/node_modules/${ompPackage}/src/cli.ts";
  ompLegacyEntrypoint = "$HOME/.bun/install/global/node_modules/${ompPackage}/src/cli.ts";
  localModelRef = "smortress/gemma-4-31b";
  smortressRolesOverride = ''
    smol: ${localModelRef}
    commit: ${localModelRef}
  '';
  smortressProviderBlock = ''
    providers:
      smortress:
        baseUrl: http://smortress:8081/v1
        api: openai-completions
        auth: none
        models:
          - id: gemma-4-31b
            name: Gemma 4 31B (smortress)
            contextWindow: 131072
            maxTokens: 131072
            cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }
            compat: { supportsDeveloperRole: false }
  '';
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
    # Declarative config.yml — generated from nix, no procedural omp config set
    home.file.".omp/agent/config.yml".text = ''
      lastChangelogVersion: 15.5.11
      modelRoles:
      ${aiCrofai.ompModelRolesYaml}
      ${smortressRolesOverride}
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
      ${smortressProviderBlock}
    '';
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
      before = [
        "configureOmpCrofAI"
        "installOmpPlugins"
      ];
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

    # config.yml and modelProviderOrder are now declarative via home.file

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
    home.activation.configureOmpCrofAI = {
      after = [ "linkGeneration" ];
      before = [ ];
      data = ''
        KEY_FILE="$HOME/.config/omp/crofai-key"
        AGENT_DIR="$HOME/.omp/agent"
        mkdir -p "$AGENT_DIR"
        chmod 700 "$AGENT_DIR" 2>/dev/null || true

        {
          echo "providers:"
          echo "  ${aiCrofai.providerId}:"
          echo "    baseUrl: ${aiCrofai.baseUrl}"
          echo "    # Precision/lightning models are intentionally omitted: they cost 3x/10x"
          echo "    # subscription requests, which is the scarce resource on CrofAI Scale."
          if [ -r "$KEY_FILE" ]; then
            echo "    apiKey: $(cat "$KEY_FILE")"
          else
            echo "    apiKey: ''''"
          fi
          echo "    api: openai-completions"
          echo "    auth: apiKey"
          echo "    models:"
          echo '${aiCrofai.ompModelsYaml}'
          echo "  smortress:"
          echo "    baseUrl: http://smortress:8081/v1"
          echo "    api: openai-completions"
          echo "    auth: none"
          echo "    models:"
          echo "      - id: gemma-4-31b"
          echo "        name: Gemma 4 31B (smortress)"
          echo "        reasoning: true"
          echo "        input: [text]"
          echo "        contextWindow: 131072"
          echo "        maxTokens: 131072"
          echo "        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }"
          echo "        compat: { supportsDeveloperRole: false }"
        } > "$AGENT_DIR/models.yml"

        if [ -r "$KEY_FILE" ]; then
          echo "[oh-my-pi] CrofAI + Smortress providers configured"
        else
          echo "[oh-my-pi] No CrofAI API key; models.yml written without apiKey"
        fi
      '';
    };
    programs.fish.shellAbbrs = {
      oc = "omp --tools read,edit,write,search,find,bash,lsp,todo_write,ask";
    };
  };
}
