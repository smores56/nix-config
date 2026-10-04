{
  config,
  lib,
  pkgs,
  ...
}:
let
  hasDm = config.dotfiles.graphical;
  inherit (pkgs.stdenv) isLinux;
in
{
  config = lib.mkIf (hasDm && isLinux) {
    home.packages = with pkgs; [
      thunar
      firefox
      evince
      feh
      libreoffice
      vlc
      gimp
      transmission_4-gtk
      discord
      musescore
      zoom-us
      krita
      steam
      chromium
    ];
  };
}
