{ wallpaper, ... }: {
  dconf = {
    enable = true;

    settings = {
      "org/gnome/desktop/applications/terminal" = {
        exec = "wezterm";
      };

      "org/gnome/desktop/interface" = {
        color-scheme = "prefer-dark";
      };

      "org/gnome/shell/extensions/pop-shell" = {
        tile-by-default = true;
      };

      "org/gnome/desktop/background" = {
        color-shading-type = "solid";
        picture-options = "zoom";
        picture-uri-dark = "file://${wallpaper}";
        primary-color = "#000000000000";
        secondary-color = "#000000000000";
      };

      "org/gnome/desktop/screensaver" = {
        color-shading-type = "solid";
        picture-options = "zoom";
        picture-uri = "file://${wallpaper}";
        primary-color = "#000000000000";
        secondary-color = "#000000000000";
      };
    };
  };
}
