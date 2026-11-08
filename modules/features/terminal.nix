{
  config,
  lib,
  pkgs,
  ...
}:
let
  shell = config.user.shell;
in
{
  fonts.fontconfig.enable = lib.mkIf config.machine.graphical true;
  home.sessionVariables = {
    TERMINAL = "kitty";
    COLORTERM = "truecolor";
  };

  programs.kitty = {
    enable = true;
    # macOS installs kitty from brew (modules/features/brew.nix); home-manager writes only the config.
    package = lib.mkIf pkgs.stdenv.hostPlatform.isDarwin null;
    settings = {
      font_family = "family='${config.user.font}' style=Regular";
      bold_font = "family='${config.user.font}' style=Bold";
      italic_font = "family='${config.user.font}' style=Italic";
      bold_italic_font = "family='${config.user.font}' style='Bold Italic'";
      font_size = 12;
      background_opacity = lib.mkForce "0.95";
      shell = "${pkgs.${shell}}/bin/${shell}";
      tab_bar_min_tabs = 2;
      hide_window_decorations = "yes";
      enable_audio_bell = "no";
      visual_bell_duration = "0.15";
      macos_option_as_alt = "both";
      wayland_enable_ime = if config.machine.wayland then "yes" else "no";
    };
  };
}
