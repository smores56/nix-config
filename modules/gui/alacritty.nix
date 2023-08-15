{ pkgs, ... }: {
  programs.alacritty = {
    enable = true;

    settings = {
      shell = "${pkgs.fish}/bin/fish";
      font = {
        size = 12;
        normal = {
          family = "CaskaydiaCove Nerd Font Mono";
        };
      };

      colors = {
        primary = {
          background = "#232136";
          foreground = "#e0def4";
        };
        cursor = {
          text = "#e0def4";
          cursor = "#56526e";
        };
        vi_mode_cursor = {
          text = "#e0def4";
          cursor = "#56526e";
        };
        line_indicator = {
          foreground = null;
          background = null;
        };
        selection = {
          text = "#e0def4";
          background = "#44415a";
        };
        normal = {
          black = "#393552";
          red = "#eb6f92";
          green = "#3e8fb0";
          yellow = "#f6c177";
          blue = "#9ccfd8";
          magenta = "#c4a7e7";
          cyan = "#ea9a97";
          white = "#e0def4";
        };
        bright = {
          black = "#6e6a86";
          red = "#eb6f92";
          green = "#3e8fb0";
          yellow = "#f6c177";
          blue = "#9ccfd8";
          magenta = "#c4a7e7";
          cyan = "#ea9a97";
          white = "#e0def4";
        };
        hints = {
          start = {
            foreground = "#908caa";
            background = "#2a273f";
          };
          end = {
            foreground = "#6e6a86";
            background = "#2a273f";
          };
        };
      };
    };
  };
}
