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

    boot.extraModprobeConfig = ''
      options nvidia NVreg_RegistryDwords=0x00800e28=0x20104000
    '';

    services.xserver.videoDrivers = [ "nvidia" ];

    environment.etc = lib.mkIf (config.dotfiles.displayManager == "niri") {
      # NVIDIA's default driver profiles cover several Wayland compositors, but
      # not niri. Limit the driver's freed-buffer pool for niri specifically.
      "nvidia/nvidia-application-profiles-rc.d/50-limit-free-buffer-pool-in-wayland-compositors.json".text =
        builtins.toJSON {
          rules = [
            {
              pattern = {
                feature = "procname";
                matches = "niri";
              };
              profile = "Limit Free Buffer Pool On Wayland Compositors";
            }
          ];
          profiles = [
            {
              name = "Limit Free Buffer Pool On Wayland Compositors";
              settings = [
                {
                  key = "GLVidHeapReuseRatio";
                  value = 0;
                }
              ];
            }
          ];
        };
    };

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
