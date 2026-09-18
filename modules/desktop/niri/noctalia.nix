{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles;
  isNiri = cfg.displayManager == "niri";
  size = cfg.monitorSize;
  hasWidgets = size != null;

  clockFormat = "{:%-I:%M %p %a, %b %d}";

  # cx/cy are the widget's centre in logical pixels; placement_width/height pin
  # the authored resolution so v5 rescales proportionally on monitor changes.
  mkWidget = type: cy: settings: {
    inherit type;
    cx = builtins.floor (size.width / 2.0);
    cy = builtins.floor (size.height * cy);
    placement_width = size.width;
    placement_height = size.height;
    inherit settings;
  };

  desktopWidgets = {
    enabled = hasWidgets;
    widget_order = [
      "clock_main"
      "media_main"
    ];
  }
  // lib.optionalAttrs hasWidgets {
    widget.clock_main = mkWidget "clock" 0.13 {
      clock_style = "digital";
      format = clockFormat;
      color = "tertiary";
    };
    widget.media_main = mkWidget "media_player" 0.40 {
      layout = "horizontal";
      hide_when_no_media = true;
    };
  };

  # The GUI writes overrides to the state dir, which loads after ~/.config and
  # wins; clear it so this declarative config is authoritative for the session.
  wipeState = pkgs.writeShellScript "noctalia-wipe-state" ''
    rm -f "''${NOCTALIA_STATE_HOME:-''${XDG_STATE_HOME:-$HOME/.local/state}}/noctalia/settings.toml"
  '';

  lockOnStart = pkgs.writeShellScript "noctalia-lock-on-start" ''
    for i in $(seq 1 60); do
      ${lib.getExe config.programs.noctalia.package} msg session lock 2>/dev/null && exit 0
      sleep 0.5
    done
    echo "lock-on-start: noctalia failed to respond after 30s" >&2
    exit 1
  '';
in
{
  config = lib.mkIf isNiri {
    # Palette and theme.mode come from stylix's Noctalia target.
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
          fingerprint = cfg.fingerprint;
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

        # v5's table is snake_case; camelCase would be silently ignored.
        desktop_widgets = desktopWidgets;
      };
    };

    systemd.user.services.noctalia.Service.ExecStartPre = "${wipeState}";

    systemd.user.services.noctalia-lock-on-start = {
      Unit = {
        Description = "Lock the session once Noctalia is up";
        After = [ "noctalia.service" ];
        PartOf = [ config.wayland.systemd.target ];
      };
      Service = {
        Type = "oneshot";
        ExecStart = "${lockOnStart}";
      };
      Install.WantedBy = [ config.wayland.systemd.target ];
    };
  };
}
