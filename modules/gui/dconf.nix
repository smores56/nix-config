{ ... }:
let
  background-config = {
    color-shading-type = "solid";
    picture-options = "zoom";
    primary-color = "#000000000000";
    secondary-color = "#000000000000";
  };
in
{
  dconf = {
    enable = true;

    settings = {
      "org/gnome/desktop/applications/terminal" = {
        exec = "kitty";
      };

      "org/gnome/shell/extensions/pop-shell" = {
        tile-by-default = true;
      };

      "org/gnome/desktop/background" = background-config;
      "org/gnome/desktop/screensaver" = background-config;
    };
  };
}
