{
  lib,
  pkgs,
  ...
}:
let
  inherit (pkgs.stdenv.hostPlatform) isLinux;

  # SteamVR's bundled Qt ships only the xcb platform plugin. The session-wide
  # QT_QPA_PLATFORM=wayland (modules/desktop/niri/settings.nix) makes vrmonitor
  # abort with "could not find or load the Qt platform plugin wayland".
  steamWithXcb = pkgs.steam.override {
    extraEnv = {
      QT_QPA_PLATFORM = "xcb";
    };
  };
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
      steamWithXcb
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
