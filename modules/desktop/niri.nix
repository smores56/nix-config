{
  config,
  lib,
  pkgs,
  ...
}:
let
  isNiri = config.dotfiles.displayManager == "niri";

  # Rose Pine Moon palette
  base = "#232136"; # background
  overlay = "#393552"; # inactive/subtle
  love = "#eb6f92"; # urgent/attention
  iris = "#c4a7e7"; # active/accent
  foam = "#9ccfd8"; # secondary accent

  niriEqualize = pkgs.writeShellScript "niri-equalize" ''
    exec ${pkgs.python3}/bin/python3 ${./niri-equalize.py}
  '';

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
      brightnessctl
      wl-clipboard
      grim
      slurp
      playerctl
    ];

    programs.niri.settings = {
      prefer-no-csd = true;
      hotkey-overlay.skip-at-startup = true;
      layout = {
        background-color = base;
        border = {
          width = 2;
          active.gradient = {
            from = iris;
            to = foam;
            angle = 135;
          };
          inactive.color = overlay;
          urgent.color = love;
        };
        shadow = {
          enable = true;
          color = "#00000050";
          inactive-color = "#00000030";
          offset = {
            x = 2;
            y = 3;
          };
          softness = 12;
          spread = 0;
        };
        tab-indicator = {
          active.color = iris;
          inactive.color = overlay;
          urgent.color = love;
        };
        insert-hint.display.color = "${iris}80";
        default-column-width.proportion = 0.5;
      };
      overview.backdrop-color = base;

      animations = {
        window-open.easing = {
          curve = "ease-out-expo";
          duration-ms = 200;
        };
        window-close.easing = {
          curve = "ease-out-expo";
          duration-ms = 150;
        };
        window-movement.spring = {
          damping-ratio = 0.8;
          stiffness = 800;
        };
        workspace-switch.spring = {
          damping-ratio = 0.8;
          stiffness = 800;
        };
        horizontal-view-movement.spring = {
          damping-ratio = 0.8;
          stiffness = 800;
        };
      };

      cursor = {
        hide-after-inactive-ms = 3000;
        hide-when-typing = true;
      };

      switch-events.lid-close.action.spawn = [
        "noctalia-shell"
        "ipc"
        "call"
        "lockScreen"
        "lock"
      ];

      spawn-at-startup = [
        { command = [ "noctalia-shell" ]; }
        {
          command = [
            "${pkgs.writeShellScript "lock-on-start" ''
              until noctalia-shell ipc call lockScreen lock 2>/dev/null; do
                sleep 0.5
              done
            ''}"
          ];
        }
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
      ];

      binds = {
        "Mod+T".action.spawn = [ config.dotfiles.terminal ];
        "Mod+B".action.spawn = [ config.dotfiles.browser ];
        "Mod+Space".action.spawn = [
          "noctalia-shell"
          "ipc"
          "call"
          "launcher"
          "toggle"
        ];
        "Mod+S".action.spawn = [
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
        "Mod+E".action.spawn = [ "${niriEqualize}" ];

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
        "Mod+L".action.spawn = [
          "noctalia-shell"
          "ipc"
          "call"
          "lockScreen"
          "lock"
        ];
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
          avatarImage = "${../../pfp.png}";
          autoStartAuth = true;
          allowPasswordWithFprintd = true;
          clockStyle = "digital";
          dimmerOpacity = 0.3;
          enableLockScreenMediaControls = true;
          lockOnSuspend = true;
          lockScreenAnimations = true;
          lockScreenBlur = 0.4;
          lockScreenTint = 0.4;
          passwordChars = true;
          showChangelogOnStartup = false;
        };
        bar.widgets = {
          left = [
            { id = "Launcher"; }
            { id = "Clock"; formatHorizontal = "h:mm AP ddd, MMM dd"; formatVertical = "h:mm AP"; tooltipFormat = "h:mm AP ddd, MMM dd"; }
            { id = "SystemMonitor"; }
            { id = "ActiveWindow"; }
            { id = "MediaMini"; }
          ];
          center = [ { id = "Workspace"; } ];
          right = [
            { id = "Tray"; }
            { id = "NotificationHistory"; }
            { id = "Battery"; }
            { id = "Volume"; }
            { id = "Brightness"; }
            { id = "ControlCenter"; }
          ];
        };
        ui = {
          fontDefault = config.dotfiles.font;
          fontFixed = config.dotfiles.font;
        };
        location = {
          useFahrenheit = true;
          use12hourFormat = true;
          analogClockInCalendar = true;
          weatherTaliaMascotAlways = true;
        };
        appLauncher = {
          enableClipboardHistory = true;
          autoPasteClipboard = true;
          terminalCommand = "${config.dotfiles.terminal} -e";
        };
        wallpaper = {
          automationEnabled = true;
          fillColor = base;
          solidColor = base;
        };
        colorSchemes = {
          predefinedScheme = "Rose Pine";
          schedulingMode = "location";
        };
        audio = {
          volumeOverdrive = true;
          volumeFeedback = true;
        };
        notifications.enableMarkdown = true;
        desktopWidgets.enabled = true;
        dock.enabled = false;
        idle.enabled = true;
        nightLight.enabled = true;
        hooks = {
          enabled = true;
          darkModeChange = "${pkgs.writeShellScript "on-dark-mode-change" ''
            export PATH="$HOME/.nix-profile/bin:$PATH"
            sleep 0.2
            exec theme-switch detect
          ''}";
        };
      };
    };
  };
}
