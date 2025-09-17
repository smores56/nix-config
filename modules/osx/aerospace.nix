{
  pkgs,
  lib,
  config,
  ...
}:
let
  allDirections = [
    "left"
    "right"
    "up"
    "down"
  ];
  gapAmount = 6;
  gapsConfig = [
    { monitor.built-in = gapAmount; }
    { monitor.main = gapAmount * 2; }
    (gapAmount * 2)
  ];

  mkWorkspaceBindingsInRange =
    {
      start,
      end,
      actionFn,
      binding,
    }:
    lib.listToAttrs (
      map (i: {
        name = "${binding}-${toString i}";
        value = (actionFn i);
      }) (lib.range start end)
    );

  mkWorkspaceBindings =
    binding: actionFn:
    mkWorkspaceBindingsInRange {
      start = 1;
      end = 9;
      actionFn = actionFn;
      binding = binding;
    };

  mkAllDirectionBindings =
    binding: actionFn:
    lib.listToAttrs (
      map (dir: {
        name = "${binding}-${dir}";
        value = (actionFn dir);
      }) allDirections
    );

  mkAppBinding = key: app: [
    "exec-and-forget open -a ${app}"
    "mode main"
  ];

  mkServiceAction =
    action: message:
    (if action == "" then [ ] else [ action ])
    ++ [
      "exec-and-forget noti -t aerospace -m \"${message}\""
      "mode main"
    ];

  mkServiceActionWithCommand =
    command: action: message:
    [
      command
    ]
    ++ mkServiceAction action message;
in
{
  home.packages = [
    pkgs.noti
    pkgs.jankyborders
  ];

  programs.aerospace = {
    enable = true;

    userSettings = {
      # config borrowed from:
      # https://github.com/marcoscurvello/dotfiles/blob/9fdc5aa65651e504934266aab6579186d67c48cc/aerospace.toml

      start-at-login = false;
      default-root-container-layout = "tiles";
      default-root-container-orientation = "auto";
      after-startup-command = [
        "layout tiles"
        "exec-and-forget ${pkgs.jankyborders}/bin/borders active_color=0xFF${config.lib.stylix.colors.base0A} inactive_color=0xFF${config.lib.stylix.colors.base04} width=${toString gapAmount} hidpi=on"
      ];

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

        cmd-ctrl-minus = "resize smart -30";
        cmd-ctrl-equal = "resize smart +30";
        cmd-ctrl-0 = "balance-sizes";
      }
      // mkAllDirectionBindings "cmd-ctrl" (d: "focus ${d}")
      // mkAllDirectionBindings "cmd-ctrl-shift" (d: "move ${d}")
      // mkWorkspaceBindings "ctrl-alt" (i: "workspace ${toString i}")
      // mkWorkspaceBindings "ctrl-alt-shift" (i: [
        "move-node-to-workspace ${toString i}"
        "workspace ${toString i}"
      ]);

      mode.move.binding = {
        esc = "mode main";
      }
      // mkAllDirectionBindings "" (d: "move ${d}")
      // mkWorkspaceBindings "" (i: [
        "move-node-to-workspace ${toString i}"
        "workspace ${toString i}"
        "mode main"
      ]);

      mode.open.binding = {
        esc = "mode main";

        t = mkAppBinding "t" "/Applications/Alacritty.app";
        b = mkAppBinding "b" "/Applications/Firefox.app";
        s = mkAppBinding "s" "/Applications/Slack.app";
        m = mkAppBinding "m" "/Applications/Spotify.app";
        f = mkAppBinding "f" "/System/Library/CoreServices/Finder.app";
      };

      mode.service.binding = {
        esc = mkServiceAction "reload-config" "Config reloaded! Back to main mode.";
        p = [
          "exec-and-forget noti -t aerospace -m \"Disabled Aerospace\""
          "enable toggle"
        ];
        b =
          mkServiceActionWithCommand "exec-and-forget brew services restart borders" ""
            "Restarted borders! Back to main mode.";
        r = mkServiceAction "flatten-workspace-tree" "Reseted layout tree! Back to main mode.";
        backspace = mkServiceAction "close-all-windows-but-current" "Closed all other windows! Back to main mode.";
      };
    };
  };
}
