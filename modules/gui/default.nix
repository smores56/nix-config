{ pkgs, ... }: {
  fonts.fontconfig.enable = true;

  imports = [
    ./dconf.nix
  ];

  home.packages = with pkgs; [
    # fonts
    nerdfonts

    # file management
    xfce.thunar
    libsForQt5.dolphin
    evince
    feh
    libreoffice

    # games
    steam
    protonup-qt

    # media
    vlc
    gimp
    transmission_4-gtk

    # other
    discord
    firefox
    kicad
    musescore
  ];
}
