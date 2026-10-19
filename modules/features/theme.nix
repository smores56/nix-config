{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.dotfiles;
in
{
  config = {
    home = {
      # stylix only sets home.pointerCursor on Linux.
      pointerCursor.enable = lib.mkIf (cfg.graphical && pkgs.stdenv.hostPlatform.isLinux) true;
    };

    stylix = {
      enable = true;
      autoEnable = true;
      polarity = "dark";
      base16Scheme = "${pkgs.base16-schemes}/share/themes/rose-pine-moon.yaml";

      fonts.monospace = {
        package = cfg.fontPackage;
        name = cfg.font;
      };

      cursor = lib.mkIf cfg.graphical {
        package = pkgs.bibata-cursors;
        name = "Bibata-Modern-Classic";
        size = 24;
      };

      targets = {
        firefox.fonts.enable = false;
        kitty.fonts.enable = false;
        kitty.opacity.enable = false;
        helix.enable = false;
        lazygit.enable = false;
        opencode.enable = false;
        gtk.enable = false;
        gnome.enable = lib.mkDefault false;
        gnome-text-editor.enable = false;
        eog.enable = false;
      };
    };
  };
}
