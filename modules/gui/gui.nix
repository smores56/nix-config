{ pkgs, ... }: {
  fonts.fontconfig.enable = true;

  imports = [ ./alacritty.nix ];

  home.packages = [
    # fonts
    pkgs.cascadia-code
    pkgs.nerdfonts

    pkgs.discord
    pkgs.firefox
    pkgs.vlc
    pkgs.evince
    pkgs.libsForQt5.dolphin
    pkgs.feh
    pkgs.kicad
    pkgs.gimp
    pkgs.libreoffice

    # TODO: install gyr from Rust/cargo
  ];
}
