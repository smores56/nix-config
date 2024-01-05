{ pkgs, ... }: {
  fonts.fontconfig.enable = true;

  imports = [
    ./dconf.nix
  ];

  home.packages = with pkgs; [
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
    nerdfonts
  ];
}
