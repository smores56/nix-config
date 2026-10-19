{
  config,
  lib,
  pkgs,
  ...
}:
let
  hasDm = config.dotfiles.graphical;
  inherit (pkgs.stdenv.hostPlatform) isLinux;
in
{
  config = lib.mkIf (hasDm && isLinux) {
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
