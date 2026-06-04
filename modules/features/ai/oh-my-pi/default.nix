{
  config,
  lib,
  pkgs,
  aiCrofai,
  ...
}:
let
  cfg = config.dotfiles.ohMyPi;
  tauCfg = config.dotfiles.tau;
  modelProviderOrder = builtins.toJSON (
    # Keep CrofAI first even when Codex/Claude credentials are imported. Those
    # providers are available for manual overrides, but CrofAI owns default roles.
    [ aiCrofai.providerId ]
    ++ (lib.optionals cfg.claude.enable [ "anthropic" ])
    ++ (lib.optionals cfg.codex.enable [ "openai-codex" ])
  );
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
  tauServiceScript = pkgs.writeShellScriptBin "omp-tau-service" ''
    exec "$HOME/.local/bin/omp" \
      --extension "$HOME/.omp/agent/extensions/tau-mirror.js" \
      --mode rpc \
      --continue
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
        "configureOmpClaude"
        "configureOmpCompaction"
        "configureOmpModelProviderOrder"
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

    home.activation.configureOmpCompaction = {
      after = [
        "linkGeneration"
        "installOmpCli"
        "configureOmpCrofAI"
      ];
      before = [ ];
      data = ''
        export PATH="$HOME/.bun/bin:$HOME/.cache/.bun/bin:$PATH"

        if ! command -v omp >/dev/null 2>&1; then
          echo "[oh-my-pi] omp not found in PATH, skipping config"
        else
          omp config set compaction.enabled true 2>/dev/null || true
          omp config set compaction.reserveTokens ${toString cfg.compaction.reserveTokens} 2>/dev/null || true
          omp config set compaction.keepRecentTokens ${toString cfg.compaction.keepRecentTokens} 2>/dev/null || true
          omp config set compaction.autoContinue ${lib.boolToString cfg.compaction.autoContinue} 2>/dev/null || true
          omp config set steeringMode one-at-a-time 2>/dev/null || true
        fi
      '';
    };

    home.activation.configureOmpModelProviderOrder = {
      after = [
        "linkGeneration"
        "installOmpCli"
        "configureOmpCrofAI"
      ];
      before = [ ];
      data = ''
        export PATH="$HOME/.bun/bin:$HOME/.cache/.bun/bin:$PATH"

        if ! command -v omp >/dev/null 2>&1; then
          echo "[oh-my-pi] omp not found in PATH, skipping model provider order config"
        else
          omp config set modelProviderOrder '${modelProviderOrder}' 2>/dev/null || true
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

    home.activation.configureOmpCrofAI = {
      after = [ "linkGeneration" ];
      before = [ ];
      data = ''
                KEY_FILE="$HOME/.config/omp/crofai-key"
                AGENT_DIR="$HOME/.omp/agent"

                if [ ! -f "$KEY_FILE" ]; then
                  echo "[oh-my-pi] No CrofAI API key at $KEY_FILE; create it with: install -m 700 -d ~/.config/omp && printf '%s' '<key>' > ~/.config/omp/crofai-key && chmod 600 ~/.config/omp/crofai-key"
                else
                  API_KEY=$(cat "$KEY_FILE")
                  mkdir -p "$AGENT_DIR"
                  chmod 700 "$AGENT_DIR" 2>/dev/null || true
                  {
                    cat << 'MODELS_HEAD'
        providers:
          ${aiCrofai.providerId}:
            baseUrl: ${aiCrofai.baseUrl}
            # Precision/lightning models are intentionally omitted: they cost 3x/10x
            # subscription requests, which is the scarce resource on CrofAI Scale.
        MODELS_HEAD
                    printf '    apiKey: %s\n' "$API_KEY"
                    cat << 'MODELS_BODY'
            api: openai-completions
            auth: apiKey
            models:
        ${aiCrofai.ompModelsYaml}MODELS_BODY
                  } > "$AGENT_DIR/models.yml"

                  cat > "$AGENT_DIR/config.yml" << 'CONFIG'
        lastChangelogVersion: 15.3.2
        # Request budget is scarcer than tokens on CrofAI Scale. Planning/default roles
        # use GLM 5.1; hard debugging gets DeepSeek V4 Pro; routine work uses
        # half/three-quarter-request models. Vision is isolated to Kimi because Kimi is
        # vision-capable but heavily quantized for text-only coding.
        modelRoles:
        ${aiCrofai.ompModelRolesYaml}
        theme:
          dark: dark-lavender
        display:
          showTokenUsage: true
          shimmer: classic
        hideThinkingBlock: false
        memory:
          backend: local
        exa:
          enableResearcher: false
        compaction:
          keepRecentTokens: ${toString cfg.compaction.keepRecentTokens}
          enabled: true
          reserveTokens: ${toString cfg.compaction.reserveTokens}
          autoContinue: ${lib.boolToString cfg.compaction.autoContinue}
        steeringMode: one-at-a-time
        extensions: []
        disabledServers:
          - beads
        tools:
          discoveryMode: mcp-only
        CONFIG

                  echo "[oh-my-pi] CrofAI models configured"
                fi
      '';
    };

    home.file.".omp/agent/extensions/wt-switch-cd.ts".source = ./wt-switch-cd.ts;

    home.activation.installTauPlugin = lib.mkIf tauCfg.enable {
      after = [
        "linkGeneration"
        "installOmpCli"
        "installOmpPlugins"
      ];
      before = [ ];
      data = ''
        export PATH="$HOME/.bun/bin:$HOME/.cache/.bun/bin:$PATH"

        TAU_REPO="https://github.com/smores56/tau.git"
        TAU_DIR="$HOME/.local/share/tau"
        EXT_DIR="$HOME/.omp/agent/extensions"
        mkdir -p "$TAU_DIR" "$EXT_DIR" 2>/dev/null || true

        if [ ! -d "$TAU_DIR/.git" ]; then
          echo "[oh-my-pi] Cloning Tau mirror to $TAU_DIR..."
          ${pkgs.git}/bin/git clone "$TAU_REPO" "$TAU_DIR" 2>&1 || echo "[oh-my-pi] Failed to clone Tau repo" >&2
        else
          echo "[oh-my-pi] Pulling Tau updates..."
          ${pkgs.git}/bin/git -C "$TAU_DIR" pull --ff-only 2>&1 || true
        fi

        if [ -d "$TAU_DIR" ]; then
          echo "[oh-my-pi] Installing Tau dependencies..."
          (cd "$TAU_DIR" && bun install) 2>&1 || true
          (cd "$TAU_DIR" && bun build extensions/mirror-server.ts --outfile=extensions/mirror-bundled.js --target=bun --external '@oh-my-pi/pi-coding-agent') 2>&1 || true
          ln -sf "$TAU_DIR/extensions/mirror-bundled.js" "$EXT_DIR/tau-mirror.js"
          ln -sfn "$TAU_DIR/public" "$EXT_DIR/public"
          rm -f "$EXT_DIR/tau-mirror.ts"
          omp config set extensions '["/home/smores/.omp/agent/extensions/tau-mirror.js"]' 2>/dev/null || true
          echo "[oh-my-pi] Tau extension built and linked to $EXT_DIR"
        fi
        TAU_PASS_FILE="${lib.escapeShellArg tauCfg.passwordFile}"
        if [ -n "$TAU_PASS_FILE" ] && [ -r "$TAU_PASS_FILE" ]; then
          PASSWORD="$(cat "$TAU_PASS_FILE")"
          SETTINGS_FILE="$HOME/.omp/agent/settings.json"
          mkdir -p "$(dirname "$SETTINGS_FILE")" 2>/dev/null || true

          if [ -r "$SETTINGS_FILE" ]; then
            tmp="$(${pkgs.coreutils}/bin/mktemp)"
            ${pkgs.jq}/bin/jq --arg user "${tauCfg.user}" --arg pass "$PASSWORD" '.tau = (.tau // {}) | .tau.user = $user | .tau.pass = $pass' "$SETTINGS_FILE" > "$tmp" && mv "$tmp" "$SETTINGS_FILE"
          else
            printf '{"tau":{"user":"%s","pass":"%s"}}\n' "${tauCfg.user}" "$PASSWORD" > "$SETTINGS_FILE"
          fi
          chmod 600 "$SETTINGS_FILE" 2>/dev/null || true
          echo "[oh-my-pi] Tau auth credentials written to settings.json"
        fi
      '';
    };
    home.file.".omp/agent/extensions/plan-mode.ts".source = ./plan-mode.ts;


    systemd.user.services.omp-tau = lib.mkIf tauCfg.enable {
      Unit = {
        Description = "OMP with Tau web mirror";
        After = "network-online.target";
        Wants = "network-online.target";
      };
      Service = {
        Type = "simple";
        ExecStart = "${tauServiceScript}/bin/omp-tau-service";
        Restart = "always";
        RestartSec = 10;
      };
      Install = {
        WantedBy = [ "default.target" ];
      };
    };
    programs.fish.shellAbbrs = {
      oc = "omp --tools read,edit,write,search,find,bash,lsp,todo_write,ask";
    };
  };
}
