{
  config,
  lib,
  ...
}:
let
  isOsx = config.dotfiles.displayManager == "osx";
  colors = config.lib.stylix.colors;
  gapAmount = 12;
in
{
  config = lib.mkIf isOsx {
    services.paneru = {
      enable = true;
      settings = {
        options = {
          preset_column_widths = [
            0.33
            0.5
            0.67
          ];
          animation_speed = 50;
        };

        padding = {
          top = gapAmount;
          bottom = gapAmount;
          left = gapAmount;
          right = gapAmount;
        };

        decorations = {
          active.border = {
            enabled = true;
            color = "#${colors.base0E}";
            width = 2.0;
            radius = 12.0;
          };
          inactive.dim.opacity = -0.15;
        };

        swipe = {
          sensitivity = 0.35;
          gesture.fingers_count = 3;
        };

        bindings = {
          window_focus_west = "ctrl - leftarrow";
          window_focus_east = "ctrl - rightarrow";
          window_focus_north = "ctrl - uparrow";
          window_focus_south = "ctrl - downarrow";

          window_swap_west = "ctrl + shift - leftarrow";
          window_swap_east = "ctrl + shift - rightarrow";
          window_swap_north = "ctrl + shift - uparrow";
          window_swap_south = "ctrl + shift - downarrow";

          window_center = "alt - c";
          window_equalize = "alt - e";
          window_stack = "alt - comma";
          window_unstack = "alt - period";

          window_fullwidth = "alt - f";
          window_manage = "alt - v";

          window_grow = "alt - equal";
          window_shrink = "alt - minus";
          window_resize = "alt - r";

          window_virtual_north = "alt + ctrl - uparrow";
          window_virtual_south = "alt + ctrl - downarrow";
          window_virtualmove_north = "alt + ctrl + shift - uparrow";
          window_virtualmove_south = "alt + ctrl + shift - downarrow";

          quit = "ctrl + alt + shift - q";
        };

        windows = {
          pip = {
            title = ".*[Pp]icture.*[Pp]icture.*";
            floating = true;
          };
          preferences = {
            title = ".*[Pp]references.*";
            floating = true;
          };
        };
      };
    };
  };
}
