{ config, lib, ... }:
{
  hardware.bluetooth.enable = lib.mkIf (config.dotfiles.displayManager != "none") true;

  fileSystems."/var/lib/bluetooth" = lib.mkIf config.dotfiles.persist {
    device = "/persist/var/lib/bluetooth";
    options = [
      "bind"
      "noauto"
      "x-systemd.automount"
    ];
    noCheck = true;
  };
}
