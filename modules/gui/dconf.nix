{ wallpaper, lightTheme, ... }:
let
  background-config = {
    color-shading-type = "solid";
    picture-options = "zoom";
    picture-uri = "file://${wallpaper}";
    picture-uri-dark = "file://${wallpaper}";
    primary-color = "#000000000000";
    secondary-color = "#000000000000";
  };
in
{
  dconf = {
    enable = true;

    settings = {
      "org/gnome/desktop/applications/terminal" = {
        exec = "wezterm";
      };

      "org/gnome/desktop/interface" = {
        color-scheme = "prefer-${if lightTheme then "light" else "dark"}";
      };

      "org/gnome/shell/extensions/pop-shell" = {
        tile-by-default = true;
      };

      "org/gnome/desktop/background" = background-config;
      "org/gnome/desktop/screensaver" = background-config;
    };
  };
}
