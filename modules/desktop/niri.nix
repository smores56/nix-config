{
  config,
  lib,
  pkgs,
  ...
}:
let
  isNiri = config.dotfiles.displayManager == "niri";

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
          if dir == "left" || dir == "right" then "${horizontalAction}-${dir}" else "${verticalAction}-${dir}";
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
        name = "Mod+Shift+${toString i}";
        value.action.move-column-to-workspace = i;
      }
    ]) (lib.range 1 9)
  );
in
{
  config = lib.mkIf isNiri {
    home.packages = with pkgs; [
      quickshell
      swaylock
      brightnessctl
      wl-clipboard
      grim
      slurp
      playerctl
    ];

    programs.niri.settings = {
      prefer-no-csd = true;

      spawn-at-startup = [
        { command = [ "noctalia-shell" ]; }
      ];

      input.touchpad = {
        natural-scroll = false;
        tap = true;
        scroll-factor = 0.5;
      };

      environment = {
        QT_QPA_PLATFORM = "wayland";
        NIXOS_OZONE_WL = "1";
      };

      window-rules = [
        {
          geometry-corner-radius = lib.genAttrs [
            "top-left"
            "top-right"
            "bottom-left"
            "bottom-right"
          ] (_: 12.0);
          clip-to-geometry = true;
        }
        {
          matches = [ { app-id = "^org\\.wezfurlong\\.wezterm$"; } ];
          default-column-width = { };
        }
      ];

      binds = {
        "Mod+T".action.spawn = [ config.dotfiles.terminal ];
        "Mod+B".action.spawn = [ config.dotfiles.browser ];
        "Mod+Space".action.spawn = [
          "qs"
          "-c"
          "noctalia-shell"
          "ipc"
          "call"
          "launcher"
          "toggle"
        ];
        "Mod+S".action.spawn = [
          "qs"
          "-c"
          "noctalia-shell"
          "ipc"
          "call"
          "controlCenter"
          "toggle"
        ];

        "Mod+Q".action.close-window = [ ];
        "Mod+F".action.maximize-column = [ ];
        "Mod+Shift+F".action.fullscreen-window = [ ];
        "Mod+V".action.toggle-window-floating = [ ];
        "Mod+Shift+V".action.switch-focus-between-floating-and-tiling = [ ];
        "Mod+W".action.toggle-column-tabbed-display = [ ];

        "Mod+Page_Up".action.focus-workspace-up = [ ];
        "Mod+Page_Down".action.focus-workspace-down = [ ];
        "Mod+Shift+Page_Up".action.move-column-to-workspace-up = [ ];
        "Mod+Shift+Page_Down".action.move-column-to-workspace-down = [ ];

        "Mod+R".action.switch-preset-column-width = [ ];
        "Mod+Minus".action.set-column-width = "-10%";
        "Mod+Equal".action.set-column-width = "+10%";
        "Mod+Shift+Minus".action.set-window-height = "-10%";
        "Mod+Shift+Equal".action.set-window-height = "+10%";

        "Mod+Comma".action.consume-window-into-column = [ ];
        "Mod+Period".action.expel-window-from-column = [ ];
        "Mod+C".action.center-column = [ ];

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
        "XF86AudioPrev".action.spawn = [
          "playerctl"
          "previous"
        ];
        "XF86AudioNext".action.spawn = [
          "playerctl"
          "next"
        ];

        "Mod+Shift+E".action.quit = { };
        "Mod+Escape".action.toggle-keyboard-shortcuts-inhibit = [ ];
        "Mod+Shift+Slash".action.show-hotkey-overlay = [ ];
        "Mod+Shift+P".action.power-off-monitors = [ ];
        "Mod+Shift+X".action.spawn = [ "swaylock" ];
      }
      // mkColumnDirectionBinds "Mod" "focus-column" "focus-window"
      // mkColumnDirectionBinds "Mod+Shift" "move-column" "move-window"
      // mkDirectionBinds "Mod+Ctrl" (dir: {
        "focus-monitor-${dir}" = [ ];
      })
      // mkDirectionBinds "Mod+Ctrl+Shift" (dir: {
        "move-column-to-monitor-${dir}" = [ ];
      })
      // workspaceBinds;
    };

    programs.noctalia-shell = {
      enable = true;
      settings = {
        general = {
          enableBlurBehind = true;
          enableShadows = true;
        };
        bar.position = "top";
        appLauncher.terminalCommand = "${config.dotfiles.terminal} -e";
        colorSchemes = {
          predefinedScheme = "Rose Pine Moon";
          darkMode = true;
        };
      };
    };
  };
}
