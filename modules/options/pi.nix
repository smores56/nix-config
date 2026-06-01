{ lib, ... }:
{
  options.dotfiles.pi = lib.mkOption {
    type = lib.types.submodule {
      options = {
        enable = lib.mkEnableOption "Pi coding agent (pi.dev)";

        defaultProvider = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
        };

        defaultModel = lib.mkOption {
          type = lib.types.str;
          default = "deepseek-v4-flash";
        };

        defaultThinkingLevel = lib.mkOption {
          type = lib.types.enum [ "off" "minimal" "low" "medium" "high" "xhigh" ];
          default = "medium";
        };

        compaction = {
          reserveTokens = lib.mkOption {
            type = lib.types.int;
            default = 8192;
          };

          keepRecentTokens = lib.mkOption {
            type = lib.types.int;
            default = 10000;
          };
        };

        packages = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [
            "git:github.com/code-yeongyu/pi-nested-agents-md"
            "npm:@aliou/pi-processes"
            "npm:@cortexkit/pi-magic-context"
            "npm:@juicesharp/rpiv-advisor"
            "npm:@juicesharp/rpiv-ask-user-question"
            "npm:@juicesharp/rpiv-todo"
            "npm:pi-lens"
            "npm:pi-multiagent"
            "npm:pi-powerline-footer"
            "npm:pi-rules"
            "npm:pi-web-access"
          ];
          description = "Pi package specs (npm:, git:) to install.";
        };
      };
    };
    default = { };
  };
}
