{ config, ... }:
let
  cfg = config.dotfiles;
in
{
  programs.wezterm = {
    enable = true;
    extraConfig = ''
      local wezterm = require 'wezterm'
      return {
        font = wezterm.font("CaskaydiaCove NF"),
        font_size = ${toString cfg.terminalFontSize},
        color_scheme = "tinted",
        window_background_opacity = 0.8,
        enable_wayland = ${if cfg.wayland then "true" else "false"},
        hide_tab_bar_if_only_one_tab = true,
        hide_mouse_cursor_when_typing = false,
        send_composed_key_when_left_alt_is_pressed = false,
        send_composed_key_when_right_alt_is_pressed = false,
        audible_bell = "Disabled",
        visual_bell = {
          fade_in_function = "EaseIn",
          fade_in_duration_ms = 150,
          fade_out_function = "EaseOut",
          fade_out_duration_ms = 150,
        },
        colors = {
          visual_bell = "#202020",
        },
        initial_cols = 200,
        initial_rows = 50,
        default_prog = { "${cfg.shellPath}" },
      }
    '';
  };
}
