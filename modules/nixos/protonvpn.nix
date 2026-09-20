{
  config,
  lib,
  pkgs,
  ...
}:
{
  config = lib.mkIf (config.dotfiles.displayManager != "none") {
    environment.systemPackages = with pkgs; [
      proton-vpn
      networkmanagerapplet
    ];

    services.gnome.gnome-keyring.enable = true;
  };
}
