{
  config,
  lib,
  ...
}:
let
  clockFormat = "{:%-I:%M %p %a, %b %d}";

in
{
  # The state file (~/.local/state/noctalia/settings.toml) is a sparse overlay of settings that deviate from this base.
  programs.noctalia = {
    enable = true;
    systemd.enable = true;

    settings = {
      shell = {
        avatar_path = "${../../../pfp.png}";
        font_family = lib.mkForce config.user.font;
        time_format = "{:%-I:%M %p}";
        clipboard_enabled = true;
        clipboard_auto_paste = "auto";
        # Logout, reboot and power off have no key; typing their name in the launcher finds them.
        launcher.providers.session.global = true;
      };

      location.auto_locate = true;

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

      # Workspaces 1-9 are declared in niri, so they always exist; show only the ones in use.
      widget.workspaces.hide_when_empty = true;

      widget.clock = {
        format = clockFormat;
        vertical_format = "{:%-I:%M %p}";
        tooltip_format = clockFormat;
      };

      wallpaper = {
        enabled = true;
        fill_color = "#${config.lib.stylix.colors.base00}";
        # The wallpapers module owns selection; Noctalia's rotation would fight it and its state file outranks this setting.
        automation.enabled = false;
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
        # v5 drives fprintd over D-Bus (strips pam_fprintd from the login stack itself); the desktop profile enables services.fprintd.
        fingerprint = true;
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

  # WantedBy graphical-session.target, which niri pulls in before exporting WAYLAND_DISPLAY: the
  # first start dies with "failed to connect to Wayland display" and the default start limit stops
  # retries, so retry until the compositor is reachable.
  # No Wants=niri.service: niri.service's BindsTo=graphical-session.target starts the target, and
  # an independent target start would launch a second niri outside niri-session.
  systemd.user.services.noctalia = {
    Unit = {
      After = lib.mkAfter [ "niri.service" ];
      StartLimitIntervalSec = 0;
    };
    Service = {
      Restart = "on-failure";
      RestartSec = 2;
    };
  };
}
