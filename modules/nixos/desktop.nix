{
  config,
  pkgs,
  lib,
  ...
}:
{
  config = lib.mkIf config.machine.graphical {
    hardware.bluetooth.enable = true;

    environment.systemPackages = [
      pkgs.playerctl
      pkgs.networkmanagerapplet
    ];

    services.pulseaudio.enable = false;
    security.rtkit.enable = true;
    services.pipewire = {
      enable = true;
      alsa.enable = true;
      alsa.support32Bit = true;
      pulse.enable = true;
    };

    services.gnome.gnome-keyring.enable = true;
  };
}
