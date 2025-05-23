{ ... }:
{
  stylix.targets.waybar.enable = true;

  programs.waybar = {
    enable = true;

    settings = [
      {
        "layer" = "top";
        "position" = "top";
        "height" = 25;
        "margin-left" = 5;
        "margin-right" = 5;
        "margin-top" = 5;
        "spacing" = 1;

        # Choose the order of the modules
        "modules-left" = [ "hyprland/workspaces" ];
        "modules-center" = [ "clock" ];
        "modules-right" = [
          "cpu"
          "temperature"
          "memory"
          "backlight"
          "pulseaudio"
          "battery"
          "network"
          "tray"
        ];

        # Modules configuration
        "hyprland/workspaces" = {
          "on-click" = "activate";
          "active-only" = false;
          "all-outputs" = true;
          "persistent-workspaces" = {
            "1" = [ ];
            "2" = [ ];
            "3" = [ ];
            "4" = [ ];
            "5" = [ ];
            "6" = [ ];
            "7" = [ ];
            "8" = [ ];
            "9" = [ ];
            "10" = [ ];
          };
          "format" = "{icon}";
          "format-icons" = {
            "1" = "";
            "2" = "";
            "3" = "";
            "4" = "";
            "5" = "";
            "6" = "";
            "7" = "";
            "8" = "";
            "9" = "󰙯";
            "10" = "";
            # "urgent" = "";
            # "active" = "";
            # "default" = ""
          };
        };
        "keyboard-state" = {
          "numlock" = true;
          "capslock" = true;
          "format" = "{name} {icon}";
          "format-icons" = {
            "locked" = "";
            "unlocked" = "";
          };
        };
        "wlr/taskbar" = {
          "format" = "{icon}";
          "icon-size" = 18;
          "tooltip-format" = "{title}";
          "on-click" = "activate";
          "on-click-middle" = "close";
          "ignore-list" = [
            "kitty"
            "wezterm"
            "foot"
            "footclient"
          ];
        };
        "tray" = {
          "icon-size" = 18;
          "spacing" = 5;
          "show-passive-items" = true;
        };
        "clock" = {
          "interval" = 60;
          "format" = "{:%a %b %d  %I:%M %p}";
        };
        "temperature" = {
          # "thermal-zone" = 2;
          # "hwmon-path" = "/sys/class/hwmon/hwmon2/temp1_input";
          # "format-critical" = "{temperatureC}°C {icon}";
          "critical-threshold" = 80;
          "interval" = 2;
          "format" = "{temperatureC}°C ";
          "format-icons" = [
            ""
            ""
            ""
          ];
        };
        "cpu" = {
          "interval" = 2;
          "format" = "{usage}%  ";
          "tooltip" = false;
        };
        "memory" = {
          "interval" = 2;
          "format" = "{}% ";
        };
        "disk" = {
          "interval" = 15;
          "format" = "{percentage_used}% 󰋊";
        };
        "backlight" = {
          "format" = "{percent}% {icon}";
          "format-icons" = [
            ""
            ""
            ""
            ""
            ""
            ""
            ""
            ""
            ""
          ];
        };
        "battery" = {
          "states" = {
            "warning" = 30;
            "critical" = 15;
          };
          "format" = "{capacity}% {icon} ";
          "format-charging" = "{capacity}% ";
          "format-plugged" = "{capacity}% ";
          "format-alt" = "{time} {icon}";
          # "format-good" = "", # An empty format will hide the module
          # "format-full" = "";
          "format-icons" = [
            ""
            ""
            ""
            ""
            ""
          ];
        };
        "battery#bat2" = {
          "bat" = "BAT2";
        };
        "network" = {
          "format-wifi" = "";
          "format-ethernet" = "{ipaddr}/{cidr} ";
          "tooltip-format-wifi" = "{essid} ({signalStrength}%) ";
          "tooltip-format" = "{ifname} via {gwaddr} ";
          "format-linked" = "{ifname} (No IP) ";
          "format-disconnected" = "Disconnected ⚠";
          "format-alt" = "{ifname} = {ipaddr}/{cidr}";
        };
        "pulseaudio" = {
          # "scroll-step" = 1, # %, can be a float
          "format" = "{volume}% {icon}"; # {format_source}";
          "format-bluetooth" = "{volume}% {icon} 󰂯"; # {format_source}";
          "format-bluetooth-muted" = "󰖁 {icon} 󰂯"; # {format_source}";
          "format-muted" = "󰖁 {format_source}";
          "format-source" = "{volume}% ";
          "format-source-muted" = "";
          "format-icons" = {
            "headphone" = "󰋋";
            "hands-free" = "󱡒";
            "headset" = "󰋎";
            "phone" = "";
            "portable" = "";
            "car" = "";
            "default" = [
              ""
              ""
              ""
            ];
          };
          "on-click" = "pactl set-sink-mute @DEFAULT_SINK@ toggle";
        };
      }
    ];
  };
}
