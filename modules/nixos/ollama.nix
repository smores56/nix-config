{ config, lib, pkgs, ... }:
{
  config = lib.mkIf config.dotfiles.ollama {
    assertions = [
      {
        assertion = config.dotfiles.nvidia;
        message = "ollama requires nvidia = true for CUDA support";
      }
    ];

    services.ollama = {
      enable = true;
      package = pkgs.ollama-cuda;
      host = "0.0.0.0";
      loadModels = [
        config.dotfiles.defaultModel
        config.dotfiles.altModel
      ];
      environmentVariables.OLLAMA_CONTEXT_LENGTH = "32768";
    };
  };
}
