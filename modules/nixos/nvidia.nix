{
  config,
  lib,
  pkgs,
  ...
}:
{
  config = lib.mkIf config.dotfiles.nvidia {
    boot.kernelModules = [ "nvidia_uvm" ];

    hardware.nvidia = {
      open = true;
      modesetting.enable = true;
      nvidiaPersistenced = true;
    };

    services.xserver.videoDrivers = [ "nvidia" ];

    systemd.services.nvidia-uvm = {
      description = "Load NVIDIA Unified Memory module";
      after = [ "systemd-modules-load.service" ];
      before = [ "llama-cpp.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        Restart = "on-failure";
        RestartSec = "2s";
        ExecStart = "${pkgs.kmod}/bin/modprobe nvidia_uvm";
      };
    };
  };
}
