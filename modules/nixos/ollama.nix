{ config, lib, pkgs, ... }:
{
  config = lib.mkIf config.dotfiles.ollama {
    dotfiles.nvidia = true;

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
