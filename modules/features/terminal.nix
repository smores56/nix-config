{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles;
  kittyApp = "${config.home.homeDirectory}/Applications/Home Manager Apps/kitty.app";
in
{
  fonts.fontconfig.enable = lib.mkIf cfg.graphical true;
  home.sessionVariables = {
    TERMINAL = cfg.terminal;
    COLORTERM = "truecolor";
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
      shell = "${pkgs.${cfg.shell}}/bin/${cfg.shell}";
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
  #
  # Its MacOS/kitty is also a nix wrapper that execs the store bundle's
  # .kitty-wrapped; leaving the copied bundle that way makes LaunchServices
  # drop the app's pid (NSRunningApplication reports -1), so AeroSpace can't
  # see its windows. Promote the copy's real binary over the wrapper first;
  # the GUI only loses the wrapper's PATH suffix, which the shell sets anyway.
  home.activation.signKittyApp = lib.mkIf pkgs.stdenv.hostPlatform.isDarwin (
    lib.hm.dag.entryAfter [ "copyApps" ] ''
      if [ -d "${kittyApp}" ]; then
        if [ -f "${kittyApp}/Contents/MacOS/.kitty-wrapped" ]; then
          $DRY_RUN_CMD mv -f "${kittyApp}/Contents/MacOS/.kitty-wrapped" "${kittyApp}/Contents/MacOS/kitty"
        fi
        $DRY_RUN_CMD /usr/bin/codesign --force --deep --sign - "${kittyApp}" >/dev/null 2>&1 || true
      fi
    ''
  );
}
