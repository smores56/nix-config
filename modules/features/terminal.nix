{ config, lib, pkgs, ... }:
let
  cfg = config.dotfiles;
  isDarwin = pkgs.stdenv.isDarwin;
  kittyApp = "${config.home.homeDirectory}/Applications/Home Manager Apps/kitty.app";
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

  # nix's kitty.app has a broken ad-hoc signature; launchd rejects GUI spawns
  # (err 162) while shell exec still works. copyApps reinstalls the broken
  # bundle every switch, so re-sign it after.
  home.activation.signKittyApp = lib.mkIf isDarwin (
    lib.hm.dag.entryAfter [ "copyApps" ] ''
      if [ -d "${kittyApp}" ]; then
        $DRY_RUN_CMD /usr/bin/codesign --force --deep --sign - "${kittyApp}" >/dev/null 2>&1 || true
      fi
    ''
  );
}
