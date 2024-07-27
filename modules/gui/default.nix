{ pkgs, displayManager, ... }: {
  fonts.fontconfig.enable = true;

  imports =
    if displayManager == "pop-os" then [
      ./dconf.nix
    ] else [ ];

  home.packages =
    if displayManager == null then [ ] else
    (with pkgs; [
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
    ]);
}
