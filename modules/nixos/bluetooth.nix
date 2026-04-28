{ config, lib, ... }:
{
  hardware.bluetooth.enable = lib.mkIf (config.dotfiles.displayManager != null) true;

  fileSystems."/var/lib/bluetooth" = lib.mkIf (builtins.pathExists "/persist") {
    device = "/persist/var/lib/bluetooth";
    options = [
      "bind"
      "noauto"
      "x-systemd.automount"
    ];
    noCheck = true;
  };
}
