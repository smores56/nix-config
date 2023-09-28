{ pkgs, lightTheme, ... }: {
  programs.wezterm = {
    enable = true;

    package = pkgs.writeShellScriptBin "wezterm" ''
      #!/bin/sh
      ${pkgs.nixgl}/bin/nixGLIntel ${pkgs.wezterm}/bin/wezterm
    '';

    extraConfig = ''
      return {
        enable_wayland = false,
        window_background_opacity = 0.9,
        hide_tab_bar_if_only_one_tab = true,
        hide_mouse_cursor_when_typing = false,
        default_prog = { "${pkgs.fish}/bin/fish" },

        font_size = 12.0,
        font = wezterm.font("CaskaydiaCove Nerd Font Mono", { weight = "Bold" }),
        color_scheme = "${if lightTheme then "rose-pine-dawn" else "rose-pine-moon"}",
        keys = {
          { key="n", mods="SHIFT|CTRL", action="ToggleFullScreen" },
        },
      }
    '';
  };
}
