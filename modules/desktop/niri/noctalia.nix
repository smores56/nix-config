{
  config,
  lib,
  pkgs,
  ...
}:
let
  isNiri = config.dotfiles.displayManager == "niri";
  polarity = config.dotfiles.polarity;

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
          fontDefault = config.dotfiles.font;
          fontFixed = config.dotfiles.font;
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
          predefinedScheme = config.dotfiles.darkTheme.noctalia;
          schedulingMode = if polarity == "timeOfDay" then "location" else "off";
        } // lib.optionalAttrs (polarity != "timeOfDay") {
          darkMode = polarity != "light";
        };
        audio = {
          volumeOverdrive = true;
          volumeFeedback = true;
        };
        notifications.enableMarkdown = true;
        desktopWidgets = {
          enabled = true;
          monitorWidgets = [
            {
              name = "eDP-1";
              widgets = [
                {
                  id = "Clock";
                  x = 550;
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
                  x = 508;
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
