{
  config,
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
      firefox
      evince
      feh
      vlc
      gimp
      transmission_4-gtk
      discord
      krita
      steam
    ];
  };
}
