{
  lib,
  pkgs,
  ...
}:
let
  inherit (pkgs.stdenv.hostPlatform) isLinux;
in
{
  config = lib.mkIf isLinux {
    home.packages = with pkgs; [
      kdePackages.dolphin
      brave-origin
      evince
      feh
      vlc
      gimp
      transmission_4-gtk
      discord
      krita
      steam
      bitwarden-menu
      bitwarden-desktop
      tutanota-desktop
    ];

    # Brave is the browser everywhere; register it so xdg-open and links follow.
    xdg.mimeApps = {
      enable = true;
      defaultApplications = {
        "text/html" = "brave-origin.desktop";
        "x-scheme-handler/http" = "brave-origin.desktop";
        "x-scheme-handler/https" = "brave-origin.desktop";
      };
    };
  };
}
