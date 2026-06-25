{ config, lib, ... }:
let
  cfg = config.dotfiles;
in
{
  fonts.fontconfig.enable = lib.mkIf (cfg.displayManager != "none") true;
  home.sessionVariables = {
    TERMINAL = cfg.terminal;
    COLORTERM = "truecolor";
    fish_terminal_skip_dsr = "1";
  };

  programs.kitty = {
    enable = true;
    settings = {
      font_family = "family='Google Sans Code' style=Regular";
      bold_font = "family='Google Sans Code' style=Bold";
      italic_font = "family='Google Sans Code' style=Italic";
      bold_italic_font = "family='Google Sans Code' style='Bold Italic'";
      font_size = cfg.terminalFontSize;
      background_opacity = lib.mkForce "0.8";
      shell = cfg.shellPath;
      tab_bar_min_tabs = 2;
      hide_window_decorations = "yes";
      enable_audio_bell = "no";
      visual_bell_duration = "0.15";
      macos_option_as_alt = "both";
      wayland_enable_ime = if cfg.wayland then "yes" else "no";
    };
  };
}
