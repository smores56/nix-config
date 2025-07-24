{ pkgs, ... }:
let
  gapsConfig = [
    { monitor.built-in = 3; }
    { monitor.main = 6; }
    6
  ];
in
{
  home.packages = with pkgs; [ noti ];

  programs.aerospace = {
    enable = true;

    userSettings = {
      # config borrowed from:
      # https://github.com/marcoscurvello/dotfiles/blob/9fdc5aa65651e504934266aab6579186d67c48cc/aerospace.toml#L2

      gaps = {
        inner = {
          horizontal = gapsConfig;
          vertical = gapsConfig;
        };

        outer = {
          left = gapsConfig;
          right = gapsConfig;
          top = gapsConfig;
          bottom = gapsConfig;
        };
      };

      mode.main.binding = {
        cmd-ctrl-esc = "mode move";
        cmd-ctrl-space = "mode open";
        cmd-ctrl-s = "mode service";

        cmd-ctrl-left = "focus left";
        cmd-ctrl-down = "focus down";
        cmd-ctrl-up = "focus up";
        cmd-ctrl-right = "focus right";

        cmd-ctrl-shift-left = "move left";
        cmd-ctrl-shift-down = "move down";
        cmd-ctrl-shift-up = "move up";
        cmd-ctrl-shift-right = "move right";

        cmd-ctrl-minus = "resize smart -30";
        cmd-ctrl-equal = "resize smart +30";
        cmd-ctrl-0 = "balance-sizes";

        ctrl-alt-1 = "workspace 1";
        ctrl-alt-2 = "workspace 2";
        ctrl-alt-3 = "workspace 3";
        ctrl-alt-4 = "workspace 4";
        ctrl-alt-5 = "workspace 5";
        ctrl-alt-6 = "workspace 6";
        ctrl-alt-7 = "workspace 7";
        ctrl-alt-8 = "workspace 8";
        ctrl-alt-9 = "workspace 9";

        ctrl-alt-shift-1 = "move-node-to-workspace 1";
        ctrl-alt-shift-2 = "move-node-to-workspace 2";
        ctrl-alt-shift-3 = "move-node-to-workspace 3";
        ctrl-alt-shift-4 = "move-node-to-workspace 4";
        ctrl-alt-shift-5 = "move-node-to-workspace 5";
        ctrl-alt-shift-6 = "move-node-to-workspace 6";
        ctrl-alt-shift-7 = "move-node-to-workspace 7";
        ctrl-alt-shift-8 = "move-node-to-workspace 8";
        ctrl-alt-shift-9 = "move-node-to-workspace 9";
      };

      mode.move.binding = {
        esc = "mode main";

        left = "move left";
        down = "move down";
        up = "move up";
        right = "move right";

        # Move window and focus to a specific worskpace
        "1" = [
          "move-node-to-workspace 1"
          "workspace 1"
          "mode main"
        ];
        "2" = [
          "move-node-to-workspace 2"
          "workspace 2"
          "mode main"
        ];
        "3" = [
          "move-node-to-workspace 3"
          "workspace 3"
          "mode main"
        ];
        "4" = [
          "move-node-to-workspace 4"
          "workspace 4"
          "mode main"
        ];
        "5" = [
          "move-node-to-workspace 5"
          "workspace 5"
          "mode main"
        ];
        "6" = [
          "move-node-to-workspace 6"
          "workspace 6"
          "mode main"
        ];
        "7" = [
          "move-node-to-workspace 7"
          "workspace 7"
          "mode main"
        ];
        "8" = [
          "move-node-to-workspace 8"
          "workspace 8"
          "mode main"
        ];
        "9" = [
          "move-node-to-workspace 9"
          "workspace 9"
          "mode main"
        ];
      };

      mode.open.binding = {
        esc = "mode main";

        t = [
          "exec-and-forget open -a /Applications/Alacritty.app"
          "mode main"
        ];
        b = [
          "exec-and-forget open -a /Applications/Firefox.app"
          "mode main"
        ];
        s = [
          "exec-and-forget open -a /Applications/Slack.app"
          "mode main"
        ];
        m = [
          "exec-and-forget open -a /Applications/Spotify.app"
          "mode main"
        ];
        f = [
          "exec-and-forget open -a /System/Library/CoreServices/Finder.app"
          "mode main"
        ];
      };

      mode.service.binding = {
        esc = [
          "reload-config"
          "exec-and-forget noti -t aerospace -m \"Config reloaded! Back to main mode.\""
          "mode main"
        ];
        p = [
          "exec-and-forget noti -t aerospace -m \"Disabled Aerospace\""
          "enable toggle"
        ];
        b = [
          "exec-and-forget brew services restart borders"
          "exec-and-forget noti -t aerospace -m \"Restarted borders! Back to main mode.\""
          "mode main"
        ];
        r = [
          "flatten-workspace-tree"
          "exec-and-forget noti -t aerospace -m \"Reseted layout tree! Back to main mode.\""
          "mode main"
        ];
        backspace = [
          "close-all-windows-but-current"
          "exec-and-forget noti -t aerospace -m \"Closed all other windows! Back to main mode.\""
          "mode main"
        ];

      };
    };
  };
}
