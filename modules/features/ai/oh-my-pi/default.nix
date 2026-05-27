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

        install_plugin "v2nic/pi-caveman"
        install_plugin "npm:pi-context-usage"
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

    home.file.".omp/agent/extensions/wt-switch-cd.ts".source = ./wt-switch-cd.ts;

    programs.fish.shellAbbrs = {
      oc = "omp --tools read,edit,write,search,find,bash,lsp,todo_write,ask";
    };
  };
}
