{
  config,
  lib,
  pkgs,
  ...
}:
let
  isNiri = config.dotfiles.displayManager == "niri";

  base = "#232136";
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
