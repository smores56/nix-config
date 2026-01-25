{ pkgs, ... }:
{

  home.packages = with pkgs; [
    # file management
    xfce.thunar
    kdePackages.dolphin
    evince
    feh
    libreoffice

    # media
    vlc
    gimp
    transmission_4-gtk

    # other
    discord
    musescore
  ];
}
