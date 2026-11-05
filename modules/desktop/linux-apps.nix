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
      brave
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
        "text/html" = "brave-browser.desktop";
        "x-scheme-handler/http" = "brave-browser.desktop";
        "x-scheme-handler/https" = "brave-browser.desktop";
      };
    };
  };
}
