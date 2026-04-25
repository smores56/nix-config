{
  config,
  lib,
  pkgs,
  ...
}:
let
  hasDm = config.dotfiles.displayManager != null;
  isLinux = pkgs.stdenv.isLinux;
in
{
  config = lib.mkIf (hasDm && isLinux) {
    home.packages = with pkgs; [
      thunar
      kdePackages.dolphin
      evince
      feh
      libreoffice
      vlc
      gimp
      transmission_4-gtk
      discord
      musescore
    ];
  };
}
