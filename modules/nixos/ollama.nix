{ config, lib, pkgs, ... }:
{
  config = lib.mkIf config.dotfiles.ollama {
    hardware.nvidia = {
      open = true;
      modesetting.enable = true;
    };
    services.xserver.videoDrivers = [ "nvidia" ];

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
