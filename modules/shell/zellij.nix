{ ... }: {
  programs.zellij = {
    enable = true;

    settings = {
      default_shell = "fish";
      ui.pane_frames.rounded_corners = true;
      themes.default = {
        fg = 7;
        bg = 23;
        black = 0;
        red = 1;
        green = 2;
        yellow = 3;
        blue = 4;
        magenta = 5;
        cyan = 6;
        white = 7;
        orange = 208;
      };
    };
  };
}
