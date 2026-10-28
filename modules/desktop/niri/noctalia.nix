{
  config,
  lib,
  pkgs,
  ...
}:
let
  clockFormat = "{:%-I:%M %p %a, %b %d}";

in
{
  # Noctalia's sparse settings.toml wins over the Nix base, including its
  # light/dark mode. Static Stylix dark has no light palette, so strip any
  # persisted [theme] table once; later GUI tweaks keep working.
  home.activation.resetNoctaliaTheme = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    state="$HOME/.local/state/noctalia/settings.toml"
    marker="$HOME/.local/state/noctalia/.stylix-static-dark"
    if [ -f "$state" ] && [ ! -e "$marker" ]; then
      ${pkgs.gawk}/bin/awk '
        /^\[/ { skip = ($0 ~ /^\[theme(\]|\.)/) }
        !skip { print }
      ' "$state" > "$state.tmp"
      mv "$state.tmp" "$state"
      touch "$marker"
    fi
  '';

  # Noctalia's state file (~/.local/state/noctalia/settings.toml) is a sparse,
  # self-pruning overlay holding only settings that deviate from this
  # declarative base; the theme itself is static dark from Stylix.
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
        # The wallpapers module owns selection per output; Noctalia's own
        # rotation would fight it, and its state file outranks this setting.
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
        # v5 drives fprintd over D-Bus (strips pam_fprintd from the login
        # stack itself); the desktop profile enables services.fprintd.
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
}
