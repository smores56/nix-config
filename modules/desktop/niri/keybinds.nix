{
  config,
  lib,
  pkgs,
  ...
}:
let
  isNiri = config.dotfiles.displayManager == "niri";

  # Documented Noctalia IPC form. niri runs both `spawn` and `spawn-sh` through
  # transient systemd units, so the shell adds no meaningful latency.
  noctalia = cmd: "noctalia msg ${cmd}";

  directionKeys = {
    Left = "left";
    Right = "right";
    Up = "up";
    Down = "down";
  };

  mkDirectionBinds =
    prefix: actionFn:
    lib.mapAttrs' (
      key: dir: lib.nameValuePair "${prefix}+${key}" { action = actionFn dir; }
    ) directionKeys;

  mkColumnDirectionBinds =
    prefix: horizontalAction: verticalAction:
    lib.mapAttrs' (
      key: dir:
      let
        action =
          if dir == "left" || dir == "right" then
            "${horizontalAction}-${dir}"
          else
            "${verticalAction}-${dir}";
      in
      lib.nameValuePair "${prefix}+${key}" { action.${action} = [ ]; }
    ) directionKeys;

  workspaceBinds = builtins.listToAttrs (
    builtins.concatMap (i: [
      {
        name = "Mod+${toString i}";
        value.action.focus-workspace = i;
      }
      {
        name = "Mod+Ctrl+${toString i}";
        value.action.move-column-to-workspace = i;
      }
    ]) (lib.range 1 9)
  );
in
{
  config = lib.mkIf isNiri {
    programs.niri.settings = {
      binds = {
        "Mod+T".action.spawn = [ config.dotfiles.terminal ];
        "Mod+B".action.spawn = [ config.dotfiles.browser ];
        "Mod+D".action.spawn-sh = noctalia "panel-toggle launcher";
        "Super+Alt+C".action.spawn-sh = noctalia "panel-toggle control-center";
        "Super+Alt+L".action.spawn-sh = noctalia "session lock";

        "Mod+Q".action.close-window = [ ];
        "Mod+O".action.toggle-overview = [ ];
        "Mod+F".action.maximize-column = [ ];
        "Mod+Shift+F".action.fullscreen-window = [ ];
        "Mod+M".action.maximize-window-to-edges = [ ];
        "Mod+Ctrl+F".action.expand-column-to-available-width = [ ];
        "Mod+V".action.toggle-window-floating = [ ];
        "Mod+Shift+V".action.switch-focus-between-floating-and-tiling = [ ];
        "Mod+W".action.toggle-column-tabbed-display = [ ];

        "Mod+Page_Up".action.focus-workspace-up = [ ];
        "Mod+Page_Down".action.focus-workspace-down = [ ];
        "Mod+Shift+Page_Up".action.move-workspace-up = [ ];
        "Mod+Shift+Page_Down".action.move-workspace-down = [ ];

        "Mod+Home".action.focus-column-first = [ ];
        "Mod+End".action.focus-column-last = [ ];
        "Mod+Ctrl+Home".action.move-column-to-first = [ ];
        "Mod+Ctrl+End".action.move-column-to-last = [ ];

        "Mod+R".action.switch-preset-column-width = [ ];
        "Mod+Shift+R".action.switch-preset-column-width-back = [ ];
        "Mod+Ctrl+Shift+R".action.switch-preset-window-height = [ ];
        "Mod+Ctrl+R".action.reset-window-height = [ ];
        "Mod+Minus".action.set-column-width = "-10%";
        "Mod+Equal".action.set-column-width = "+10%";
        "Mod+Shift+Minus".action.set-window-height = "-10%";
        "Mod+Shift+Equal".action.set-window-height = "+10%";

        "Mod+BracketLeft".action.consume-or-expel-window-left = [ ];
        "Mod+BracketRight".action.consume-or-expel-window-right = [ ];
        "Mod+Comma".action.consume-window-into-column = [ ];
        "Mod+Period".action.expel-window-from-column = [ ];
        "Mod+C".action.center-column = [ ];
        "Mod+Ctrl+C".action.center-visible-columns = [ ];

        "Mod+Shift+Space".action.switch-layout = "prev";

        "Print".action.screenshot = [ ];
        "Ctrl+Print".action.screenshot-screen = [ ];
        "Alt+Print".action.screenshot-window = [ ];

        "XF86AudioRaiseVolume".action.spawn = [
          "wpctl"
          "set-volume"
          "-l"
          "1.0"
          "@DEFAULT_AUDIO_SINK@"
          "0.1+"
        ];
        "XF86AudioLowerVolume".action.spawn = [
          "wpctl"
          "set-volume"
          "@DEFAULT_AUDIO_SINK@"
          "0.1-"
        ];
        "XF86AudioMute".action.spawn = [
          "wpctl"
          "set-mute"
          "@DEFAULT_AUDIO_SINK@"
          "toggle"
        ];
        "XF86AudioMicMute".action.spawn = [
          "wpctl"
          "set-mute"
          "@DEFAULT_AUDIO_SOURCE@"
          "toggle"
        ];
        "XF86MonBrightnessUp".action.spawn = [
          "brightnessctl"
          "set"
          "+10%"
        ];
        "XF86MonBrightnessDown".action.spawn = [
          "brightnessctl"
          "set"
          "10%-"
        ];
        "XF86AudioPlay".action.spawn = [
          "playerctl"
          "play-pause"
        ];
        "XF86AudioPause".action.spawn = [
          "playerctl"
          "play-pause"
        ];
        "XF86AudioStop".action.spawn = [
          "playerctl"
          "stop"
        ];
        "XF86AudioPrev".action.spawn = [
          "playerctl"
          "previous"
        ];
        "XF86AudioNext".action.spawn = [
          "playerctl"
          "next"
        ];

        "Mod+Shift+E".action.quit = { };
        "Ctrl+Alt+Delete".action.quit = { };
        "Mod+Escape".action.toggle-keyboard-shortcuts-inhibit = [ ];
        "Mod+Shift+Slash".action.show-hotkey-overlay = [ ];
        "Mod+Shift+P".action.power-off-monitors = [ ];

        "Mod+WheelScrollDown" = {
          cooldown-ms = 150;
          action.focus-workspace-down = [ ];
        };
        "Mod+WheelScrollUp".action.focus-workspace-up = [ ];
        "Mod+Ctrl+WheelScrollDown".action.move-column-to-workspace-down = [ ];
        "Mod+Ctrl+WheelScrollUp".action.move-column-to-workspace-up = [ ];
        "Mod+WheelScrollRight".action.focus-column-right = [ ];
        "Mod+WheelScrollLeft".action.focus-column-left = [ ];
        "Mod+Ctrl+WheelScrollRight".action.move-column-right = [ ];
        "Mod+Ctrl+WheelScrollLeft".action.move-column-left = [ ];
        "Mod+Shift+WheelScrollDown".action.focus-column-right = [ ];
        "Mod+Shift+WheelScrollUp".action.focus-column-left = [ ];
        "Mod+Ctrl+Shift+WheelScrollDown".action.move-column-right = [ ];
        "Mod+Ctrl+Shift+WheelScrollUp".action.move-column-left = [ ];
      }
      // mkColumnDirectionBinds "Mod" "focus-column" "focus-window"
      // mkColumnDirectionBinds "Mod+Ctrl" "move-column" "move-window"
      // mkDirectionBinds "Mod+Shift" (dir: {
        "focus-monitor-${dir}" = [ ];
      })
      // mkDirectionBinds "Mod+Ctrl+Shift" (dir: {
        "move-column-to-monitor-${dir}" = [ ];
      })
      // workspaceBinds;
    };
  };
}
