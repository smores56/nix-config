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
