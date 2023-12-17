{ pkgs, lightTheme, ... }: {
  programs.wezterm = {
    enable = true;

    package =
      if pkgs.stdenv.isLinux
      then
        (pkgs.writeShellScriptBin "wezterm" ''
          #!/bin/sh
          ${pkgs.nixgl}/bin/nixGLIntel ${pkgs.wezterm}/bin/wezterm
        '')
      else pkgs.wezterm;

    extraConfig = ''
      return {
        enable_wayland = false,
        window_background_opacity = 0.9,
        hide_tab_bar_if_only_one_tab = true,
        hide_mouse_cursor_when_typing = false,
        color_scheme = ${if lightTheme then "\"Gruvbox light, medium (base16)\"" else "\"Monokai Pro Ristretto (Gogh)\""},
        hide_tab_bar_if_only_one_tab = true,
        initial_cols = 200,
        initial_rows = 50,
        default_prog = { "${pkgs.fish}/bin/fish" },

        font_size = 12.0,
        font = wezterm.font("CaskaydiaCove Nerd Font Mono", { weight = "Bold" }),
        keys = {
          {key="n", mods="SHIFT|CTRL", action="ToggleFullScreen"},
        }
      }
    '';
  };
}
