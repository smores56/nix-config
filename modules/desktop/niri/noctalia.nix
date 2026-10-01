{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles;
  isNiri = cfg.displayManager == "niri";

  clockFormat = "{:%-I:%M %p %a, %b %d}";

  # Noctalia's state file (~/.local/state/noctalia/settings.toml) is a sparse,
  # self-pruning overlay holding only settings that deviate from this declarative
  # base — so it is left in place, and Noctalia's own theme mode stays the source
  # of truth for light/dark.
  themeApply = import ../../lib/theme-apply.nix { inherit pkgs lib; };
in
{
  config = lib.mkIf isNiri {
    # Stylix writes the base palette and theme.mode into config.toml; Noctalia's
    # own toggle persists to settings.toml, which wins — so its mode is the
    # source of truth and the hooks below propagate it to the rest of the system.
    programs.noctalia = {
      enable = true;
      systemd.enable = true;

      settings = {
        shell = {
          avatar_path = "${../../../pfp.png}";
          font_family = lib.mkForce cfg.font;
          time_format = "{:%-I:%M %p}";
          clipboard_enabled = true;
          clipboard_auto_paste = "auto";
        };

        location.auto_locate = true;

        # Noctalia's theme mode drives the rest of the system: sync on start and
        # follow every change, via the native push hooks.
        hooks = {
          started = "${themeApply}/bin/theme-apply \"$(noctalia msg theme-mode-get)\"";
          theme_mode_changed = "${themeApply}/bin/theme-apply \"$NOCTALIA_THEME_MODE\"";
        };

        bar.main = {
          position = "top";
          start = [
            "launcher"
            "clock"
            "sysmon"
            "active_window"
            "media"
          ];
          center = [ "workspaces" ];
          end = [
            "tray"
            "notifications"
            "battery"
            "volume"
            "brightness"
            "control-center"
          ];
        };

        widget.clock = {
          format = clockFormat;
          vertical_format = "{:%-I:%M %p}";
          tooltip_format = clockFormat;
        };

        wallpaper = {
          enabled = true;
          fill_color = "#${config.lib.stylix.colors.base00}";
          automation.enabled = true;
        };

        weather = {
          enabled = true;
          unit = "fahrenheit";
        };

        audio = {
          enable_overdrive = true;
          enable_sounds = true;
        };

        lockscreen = {
          enabled = true;
          lock_before_suspend = true;
          # v5 drives fprintd over D-Bus (strips pam_fprintd from the login
          # stack itself); requires services.fprintd from dotfiles.fingerprint.
          inherit (cfg) fingerprint;
          blur_intensity = 0.4;
          tint_intensity = 0.4;
        };

        nightlight.enabled = true;
        dock.enabled = false;

        idle.behavior = {
          lock = {
            enabled = true;
            timeout = 600;
            action = "lock";
          };
          screen-off = {
            enabled = true;
            timeout = 660;
            action = "screen_off";
          };
        };
      };
    };
  };
}
