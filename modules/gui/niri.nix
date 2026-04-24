{ ... }:
{
  programs.niri = {
    enable = true;
    settings = {
      spawn-at-startup = [
        { argv = [ "noctalia-shell" ]; }
      ];
      input.touchpad = {
        natural-scroll = true;
        tap = true;
      };
      environment = {
        QT_QPA_PLATFORM = "wayland";
        NIXOS_OZONE_WL = "1";
      };
    };
  };

  programs.noctalia-shell = {
    enable = true;
    settings = {
      general = {
        enableBlurBehind = true;
        enableShadows = true;
      };
      bar.position = "top";
      appLauncher.terminalCommand = "wezterm -e";
      colorSchemes.darkMode = true;
    };
  };
}
