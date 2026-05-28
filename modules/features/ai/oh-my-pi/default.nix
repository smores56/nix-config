{
  config,
  lib,
  ...
}:
let
  cfg = config.dotfiles.ohMyPi;
in
{
  options.dotfiles.ohMyPi = {
    enable = lib.mkEnableOption "oh-my-pi token-efficient config" // {
      description = "Enable aggressive compaction, plugin installation, and tool-pinned abbreviation for omp.";
    };

    compaction = {
      reserveTokens = lib.mkOption {
        type = lib.types.int;
        default = 16384;
        description = "Token budget reserved for agent output after compaction.";
      };
      keepRecentTokens = lib.mkOption {
        type = lib.types.int;
        default = 12000;
        description = "Number of recent tokens preserved during compaction.";
      };
      autoContinue = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Automatically continue after compaction instead of prompting.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    home.activation.installOmpPlugins = {
      after = [ "linkGeneration" ];
      before = [ ];
      data = ''
        export PATH="$HOME/.cache/.bun/bin:$HOME/.bun/bin:$PATH"

        if ! command -v omp >/dev/null 2>&1; then
          echo "[oh-my-pi] omp not found in PATH, skipping plugin install"
          exit 0
        fi

        install_plugin() {
          local name="$1"
          if ! omp plugin list 2>/dev/null | grep -q "$name"; then
            omp plugin install "$name" 2>&1 || true
          fi
        }

        install_plugin "pi-caveman"
        install_plugin "pi-context-usage"
      '';
    };

    home.activation.configureOmpCompaction = {
      after = [ "linkGeneration" ];
      before = [ ];
      data = ''
        export PATH="$HOME/.cache/.bun/bin:$HOME/.bun/bin:$PATH"

        if ! command -v omp >/dev/null 2>&1; then
          echo "[oh-my-pi] omp not found in PATH, skipping config"
          exit 0
        fi

        omp config set compaction.enabled true 2>/dev/null || true
        omp config set compaction.reserveTokens ${toString cfg.compaction.reserveTokens} 2>/dev/null || true
        omp config set compaction.keepRecentTokens ${toString cfg.compaction.keepRecentTokens} 2>/dev/null || true
        omp config set compaction.autoContinue ${lib.boolToString cfg.compaction.autoContinue} 2>/dev/null || true
        omp config set steeringMode one-at-a-time 2>/dev/null || true
      '';
    };

    home.activation.configureOmpMinimax = {
      after = [ "linkGeneration" ];
      before = [ ];
      data = ''
        KEY_FILE="$HOME/.config/omp/minimax-key"
        AGENT_DIR="$HOME/.omp/agent"

        if [ ! -f "$KEY_FILE" ]; then
          echo "[oh-my-pi] No MiniMax API key at $KEY_FILE, skipping minimax config"
          exit 0
        fi

        # Read key and replace sentinel in templates
        API_KEY=$(cat "$KEY_FILE")

        # Provider "minimax-code" triggers the built-in thinking tag parser in pi-ai
        sed -e "s/__API_KEY__/$API_KEY/g" << 'MODELS' > "$AGENT_DIR/models.yml"
providers:
  minimax-code:
    baseUrl: https://api.minimax.io/v1
    apiKey: __API_KEY__
    api: openai-completions
    auth: apiKey
    models:
      - id: MiniMax-M2.7
        name: MiniMax M2.7
        reasoning: false
        input: [text]
        contextWindow: 204800
        maxTokens: 32000
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }
        compat: { supportsDeveloperRole: false }
MODELS

        cat << 'CONFIG' > "$AGENT_DIR/config.yml"
lastChangelogVersion: 15.3.2
modelRoles:
  default: minimax-code/MiniMax-M2.7
  slow: minimax-code/MiniMax-M2.7
  plan: minimax-code/MiniMax-M2.7
  smol: minimax-code/MiniMax-M2.7
theme:
  dark: dark-lavender
display:
  showTokenUsage: true
  shimmer: classic
hideThinkingBlock: false
memory:
  backend: local
exa:
  enableResearcher: true
compaction:
  keepRecentTokens: 12000
  enabled: true
  reserveTokens: 16384
  autoContinue: true
steeringMode: one-at-a-time
extensions: []
disabledServers:
  - beads
tools:
  discoveryMode: mcp-only
CONFIG

        echo "[oh-my-pi] MiniMax M2.7 configured"
      '';
    };

    home.file.".omp/agent/extensions/wt-switch-cd.ts".source = ./wt-switch-cd.ts;

    programs.fish.shellAbbrs = {
      oc = "omp --tools read,edit,write,search,find,bash,lsp,todo_write,ask";
    };
  };
}