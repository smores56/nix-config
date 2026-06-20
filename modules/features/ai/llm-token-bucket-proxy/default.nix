{
  config,
  lib,
  pkgs,
  ...
}:
{
  options.dotfiles.llmTokenBucketProxy = lib.mkOption {
    description = "Local token-bucket budget proxy that sits in front of LiteLLM.";
    default = { };
    type = lib.types.submodule {
      options = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Run the llm-token-bucket-proxy user service.";
        };
        src = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Path to the llm-token-bucket-proxy checkout. Null uses codeRoot default.";
        };
        configFile = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Path to the proxy config.yaml. Null uses XDG default.";
        };
        environmentFile = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Optional env file exporting upstream/admin/client keys.";
        };
      };
    };
  };

  config = lib.mkIf config.dotfiles.llmTokenBucketProxy.enable {
    home.packages = [ pkgs.bun ];

    systemd.user.services.llm-token-bucket-proxy = lib.mkIf pkgs.stdenv.isLinux {
      Unit = {
        Description = "LLM Token Bucket Proxy";
        After = [ "network.target" ];
      };
      Service = {
        ExecStart = let
          cfg = config.dotfiles.llmTokenBucketProxy;
          src = if cfg.src != null then cfg.src else "${config.dotfiles.codeRoot}/github.com/smores56/llm-token-bucket-proxy";
          configFile = if cfg.configFile != null then cfg.configFile else "${config.home.homeDirectory}/.config/llm-token-bucket-proxy/config.yaml";
        in "${pkgs.bun}/bin/bun ${src}/src/main.ts serve --config ${configFile}";
        WorkingDirectory = let cfg = config.dotfiles.llmTokenBucketProxy;
        in if cfg.src != null then cfg.src else "${config.dotfiles.codeRoot}/github.com/smores56/llm-token-bucket-proxy";
        Restart = "always";
        RestartSec = 5;
      } // lib.optionalAttrs (config.dotfiles.llmTokenBucketProxy.environmentFile != null) {
        EnvironmentFile = config.dotfiles.llmTokenBucketProxy.environmentFile;
      };
      Install.WantedBy = [ "default.target" ];
    };
  };
}
