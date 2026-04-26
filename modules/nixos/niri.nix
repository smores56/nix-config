{
  config,
  lib,
  pkgs,
  ...
}:
{
  config = lib.mkIf (config.dotfiles.displayManager == "niri") {
    programs.niri.enable = true;

    services = {
      libinput.enable = true;
      upower.enable = true;
      power-profiles-daemon.enable = true;
    };

    nix.settings = {
      substituters = [ "https://noctalia.cachix.org" ];
      trusted-public-keys = [ "noctalia.cachix.org-1:pCOR47nnMEo5thcxNDtzWpOxNFQsBRglJzxWPp3dkU4=" ];
    };

    programs.regreet = {
      enable = true;
      cageArgs = [
        "-s"
        "-d"
        "-m"
        "last"
      ];
      settings = {
        GTK.application_prefer_dark_theme = true;
        background = {
          path = "${../../wallpapers/spirited-away.jpg}";
          fit = "Cover";
        };
      };
      theme = {
        package = pkgs.adw-gtk3;
        name = "adw-gtk3-dark";
      };
      iconTheme = {
        package = pkgs.papirus-icon-theme;
        name = "Papirus-Dark";
      };
      cursorTheme = {
        package = pkgs.bibata-cursors;
        name = "Bibata-Modern-Classic";
      };
      font = {
        package = config.dotfiles.fontPackage;
        name = config.dotfiles.font;
        size = 16;
      };
    };
  };
}
