{ pkgs, lightTheme, ... }: {
  programs.wezterm = {
    enable = true;

    extraConfig = ''
      return {
        font = wezterm.font("CaskaydiaCove Nerd Font Mono", { weight = "Bold" }),
        font_size = 12.0,
        color_scheme = "${if lightTheme then "rose-pine-dawn" else "rose-pine-moon"}",
        window_background_opacity = 0.9,
        hide_tab_bar_if_only_one_tab = true,
        hide_mouse_cursor_when_typing = false,
        default_prog = { "${pkgs.fish}/bin/fish" },
        keys = {
          { key="n", mods="SHIFT|CTRL", action="ToggleFullScreen" },
        },
      }
    '';
  };
}
