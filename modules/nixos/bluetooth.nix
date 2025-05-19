{ ... }:
{
  hardware.bluetooth.enable = true;

  fileSystems."/var/lib/bluetooth" = {
    device = "/persist/var/lib/bluetooth";
    options = [
      "bind"
      "noauto"
      "x-systemd.automount"
    ];
    noCheck = true;
  };
}
