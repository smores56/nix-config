{ pkgs, ... }: {
  fonts.fontconfig.enable = true;

  imports = [
    ./terminal
  ];

  home.packages = with pkgs; [
    # fonts
    cascadia-code
    nerdfonts

    discord
    firefox
    vlc
    evince
    libsForQt5.dolphin
    feh
    kicad
    gimp
    libreoffice
  ];
}
