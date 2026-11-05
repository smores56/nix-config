{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (config.lib.stylix) colors;
  shared = import ../shared-bindings.nix { inherit lib; };
  # Connector names are per machine: the laptop panel is eDP-1, and an unmatched name makes niri
  # open the workspace on the focused output, so a lone laptop still gets all nine.
  outputs = {
    builtIn = "eDP-1";
    external = "DP-1";
  };
  commsWorkspace = 2;
  workspaceOutput = i: if i == commsWorkspace then outputs.builtIn else outputs.external;
  defaultSpring = {
    damping-ratio = 0.8;
    stiffness = 800;
    epsilon = 0.0001;
  };
in
{
  home.packages = with pkgs; [
    brightnessctl
    wl-clipboard
    grim
    slurp
    playerctl
  ];

  # Qt on Wayland (Krita falls back to XWayland, where tablets get no pen input). In the systemd
  # user environment, not niri's `environment`: Noctalia runs as a user service, so apps it spawns never inherit niri's.
  xdg.configFile."environment.d/20-qt-wayland.conf".text = ''
    QT_QPA_PLATFORM=wayland
    NIXOS_OZONE_WL=1
  '';

  programs.niri.package = pkgs.niri-unstable;
  programs.niri.settings = {
    prefer-no-csd = true;
    hotkey-overlay.skip-at-startup = true;
    layout = {
      gaps = shared.gaps.compact;
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
      window-movement.kind.spring = defaultSpring;
      workspace-switch.kind.spring = defaultSpring;
      horizontal-view-movement.kind.spring = defaultSpring;
    };

    cursor = {
      hide-after-inactive-ms = 3000;
      hide-when-typing = true;
    };

    input = {
      keyboard = {
        repeat-delay = shared.input.repeatDelayMs;
        repeat-rate = shared.input.repeatRate;
      };

      touchpad = {
        natural-scroll = shared.input.naturalScroll;
        tap = true;
        scroll-factor = shared.input.scrollFactor;
      };
      mouse.natural-scroll = shared.input.naturalScroll;
    };

    workspaces = lib.listToAttrs (
      map (i: {
        name = "w${toString i}";
        value = {
          name = toString i;
          open-on-output = workspaceOutput i;
        };
      }) (lib.range 1 9)
    );

    window-rules = [
      {
        matches = [
          { app-id = "^kitty$"; }
          { app-id = "^brave-origin$"; }
        ];
        open-on-workspace = "1";
      }
      {
        draw-border-with-background = false;
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
}
