{
  config,
  lib,
  pkgs,
  ...
}:
let
  hasDm = config.dotfiles.displayManager != "none";
  inherit (pkgs.stdenv) isLinux;
in
{
  config = lib.mkIf (hasDm && isLinux) {
    home.packages = with pkgs; [
      thunar
      kdePackages.dolphin
      firefox
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
