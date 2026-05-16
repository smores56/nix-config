{ config, lib, ... }:
let
  cfg = config.dotfiles;
in
{
  fonts.fontconfig.enable = lib.mkIf (cfg.displayManager != "none") true;
  home.sessionVariables = lib.mkIf (cfg.displayManager != "none") {
    TERMINAL = cfg.terminal;
  };

  programs.kitty = {
    enable = true;
    settings = {
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
