{
  config,
  lib,
  pkgs,
  ...
}:
let
  isNiri = config.dotfiles.displayManager == "niri";
  colors = config.lib.stylix.colors;
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

    programs.niri.package = pkgs.niri-unstable;
    programs.niri.settings = {
      prefer-no-csd = true;
      hotkey-overlay.skip-at-startup = true;
      layout = {
        background-color = "#${colors.base00}";
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
        insert-hint.display.color = "#${colors.base0E}80";
        default-column-width.proportion = 0.5;
      };
      overview.backdrop-color = "#${colors.base00}";

      animations = {
        window-open.kind.easing = {
          curve = "ease-out-expo";
          duration-ms = 200;
        };
        window-close.kind.easing = {
          curve = "ease-out-expo";
          duration-ms = 150;
        };
        window-movement.kind.spring = {
          damping-ratio = 0.8;
          stiffness = 800;
          epsilon = 0.0001;
        };
        workspace-switch.kind.spring = {
          damping-ratio = 0.8;
          stiffness = 800;
          epsilon = 0.0001;
        };
        horizontal-view-movement.kind.spring = {
          damping-ratio = 0.8;
          stiffness = 800;
          epsilon = 0.0001;
        };
      };

      cursor = {
        hide-after-inactive-ms = 3000;
        hide-when-typing = true;
      };

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
    };
  };
}
