{ config, lib, ... }:
{
  config = lib.mkIf config.dotfiles.nvidia {
    hardware.nvidia = {
      open = true;
      modesetting.enable = true;
    };
    services.xserver.videoDrivers = [ "nvidia" ];
  };
}
