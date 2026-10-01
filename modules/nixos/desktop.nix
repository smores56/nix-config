{
  config,
  pkgs,
  lib,
  ...
}:
{
  config = lib.mkIf config.dotfiles.graphical {
    hardware.bluetooth.enable = true;

    # Audio (PipeWire) and the GNOME keyring for desktop credentials.
    environment.systemPackages = [
      pkgs.pulseaudio
      pkgs.playerctl
      pkgs.proton-vpn
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
