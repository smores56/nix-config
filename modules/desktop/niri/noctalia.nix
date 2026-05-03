{
  config,
  lib,
  pkgs,
  ...
}:
let
  isNiri = config.dotfiles.displayManager == "niri";
  polarity = config.dotfiles.polarity;
  monitor = config.dotfiles.primaryMonitor;
  size = config.dotfiles.monitorSize;
  hasWidgets = monitor != null && size != null;

  # Reference resolution all widget positions/scales are authored against
  refSize = { width = 1920; height = 1080; };

  # Scale a widget definition from refSize to the target monitor.
  # Each widget carries a `refWidth` (measured pixel width at its authored scale)
  # used to horizontally center it; this key is stripped from the output.
  scaleWidget =
    widget:
    let
      factor = (size.height * 1.0) / refSize.height;
    in
    (removeAttrs widget [ "refWidth" ]) // {
      x = builtins.floor ((size.width - widget.refWidth * factor) / 2.0);
      y = builtins.floor (widget.y * factor);
      scale = widget.scale * factor;
    };

  base = "#${config.lib.stylix.colors.base00}";
in
{
  config = lib.mkIf isNiri {
    programs.noctalia-shell = {
      enable = true;
      settings = {
        general = {
          avatarImage = "${../../../pfp.png}";
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
            {
              id = "Clock";
              formatHorizontal = "h:mm AP ddd, MMM dd";
              formatVertical = "h:mm AP";
              tooltipFormat = "h:mm AP ddd, MMM dd";
            }
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
          fontDefault = lib.mkForce config.dotfiles.font;
          fontFixed = lib.mkForce config.dotfiles.font;
        };
        location = {
          useFahrenheit = true;
          use12hourFormat = true;
          analogClockInCalendar = true;
          weatherTaliaMascotAlways = false;
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
          predefinedScheme =
            if polarity == "light" then config.dotfiles.lightTheme.noctalia
            else config.dotfiles.darkTheme.noctalia;
          schedulingMode = if polarity == "time-of-day" then "location" else "off";
        } // lib.optionalAttrs (polarity != "time-of-day") {
          darkMode = polarity != "light";
        };
        audio = {
          volumeOverdrive = true;
          volumeFeedback = true;
        };
        notifications.enableMarkdown = true;
        desktopWidgets = {
          enabled = hasWidgets;
          monitorWidgets = lib.optionals hasWidgets [
            {
              name = monitor;
              widgets = map scaleWidget [
                {
                  id = "Clock";
                  refWidth = 820;
                  y = 24;
                  scale = 3.5;
                  showBackground = false;
                  clockColor = "tertiary";
                  clockStyle = "minimal";
                  format = "h:mm AP\\nddd, MMM dd";
                  roundedCorners = true;
                }
                {
                  id = "MediaPlayer";
                  refWidth = 904;
                  y = 312;
                  scale = 1.3;
                  showBackground = true;
                  showButtons = true;
                  showAlbumArt = true;
                  showVisualizer = true;
                  visualizerType = "wave";
                  hideMode = "idle";
                  roundedCorners = true;
                }
              ];
            }
          ];
        };
        sessionMenu.countdownDuration = 5000;
        dock.enabled = false;
        idle.enabled = true;
        nightLight.enabled = true;
        hooks = {
          enabled = true;
          darkModeChange = "${config.dotfiles.darkModeHook} $1";
        };
      };
    };
  };
}
