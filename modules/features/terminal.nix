{ config, lib, ... }:
let
  cfg = config.dotfiles;
in
{
  fonts.fontconfig.enable = lib.mkIf (cfg.displayManager != null) true;
  home.sessionVariables.TERMINAL = lib.mkIf (cfg.displayManager != null) cfg.terminal;

  programs.wezterm = {
    enable = true;
    extraConfig = ''
      local wezterm = require 'wezterm'
      local config = wezterm.config_builder()

      config.font = wezterm.font("${cfg.font}")
      config.font_size = ${toString cfg.terminalFontSize}
      config.window_background_opacity = 0.8
      config.enable_wayland = ${if cfg.wayland then "true" else "false"}
      config.hide_tab_bar_if_only_one_tab = true
      config.hide_mouse_cursor_when_typing = false
      config.send_composed_key_when_left_alt_is_pressed = false
      config.send_composed_key_when_right_alt_is_pressed = false
      config.audible_bell = "Disabled"
      config.visual_bell = {
        fade_in_function = "EaseIn",
        fade_in_duration_ms = 150,
        fade_out_function = "EaseOut",
        fade_out_duration_ms = 150,
      }
      config.default_prog = { "${cfg.shellPath}" }

      local function scheme_for_appearance(appearance)
        if appearance:find("Dark") then
          return "Rosé Pine Moon (Gogh)"
        else
          return "Rosé Pine Dawn (Gogh)"
        end
      end

      config.color_scheme = scheme_for_appearance(wezterm.gui.get_appearance())

      wezterm.on("window-config-reloaded", function(window, pane)
        local overrides = window:get_config_overrides() or {}
        local scheme = scheme_for_appearance(window:get_appearance())
        if overrides.color_scheme ~= scheme then
          overrides.color_scheme = scheme
          window:set_config_overrides(overrides)
        end
      end)

      return config
    '';
  };
}
