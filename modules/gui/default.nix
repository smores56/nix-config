{ pkgs, ... }: {
  fonts.fontconfig.enable = true;

  imports = [
    ./dconf.nix
  ];

  home.packages = with pkgs; [
    # fonts
    nerdfonts

    discord
    firefox
    vlc
    evince
    libsForQt5.dolphin
    feh
    libreoffice
    kicad
    gimp
    musescore
    transmission_4-gtk
    steam
    protonup-qt
  ];
}
