{
  config,
  lib,
  pkgs,
  ...
}:
let
  isOsx = config.dotfiles.displayManager == "osx";

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

  mkPrefixedBindings =
    prefix: items: actionFn:
    lib.listToAttrs (
      map (item: {
        name = "${prefix}-${toString item}";
        value = actionFn item;
      }) items
    );

  mkWorkspaceBindings = binding: actionFn: mkPrefixedBindings binding (lib.range 1 9) actionFn;
  mkAllDirectionBindings = binding: actionFn: mkPrefixedBindings binding allDirections actionFn;

  mkAppBinding = app: [
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
  config = lib.mkIf isOsx {
    home.packages = [
      pkgs.noti
      pkgs.jankyborders
    ];

    programs.aerospace = {
      enable = true;

      settings = {
        start-at-login = false;
        default-root-container-layout = "tiles";
        default-root-container-orientation = "auto";
        after-startup-command = [
          "layout tiles"
          "exec-and-forget ${pkgs.jankyborders}/bin/borders active_color=0xFFea9a97 inactive_color=0xFF908caa width=${toString gapAmount} hidpi=on"
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

        mode = {
          main.binding = {
            cmd-ctrl-esc = "mode move";
            cmd-ctrl-space = "mode open";
            cmd-ctrl-s = "mode service";
            cmd-ctrl-minus = "resize smart -30";
            cmd-ctrl-equal = "resize smart +30";
            cmd-ctrl-0 = "balance-sizes";
            cmd-ctrl-e = "layout tiles horizontal vertical";
            cmd-ctrl-a = "layout accordion horizontal vertical";
          }
          // mkAllDirectionBindings "cmd-ctrl" (d: "focus ${d}")
          // mkAllDirectionBindings "cmd-ctrl-shift" (d: "move ${d}")
          // mkWorkspaceBindings "ctrl-alt" (i: "workspace ${toString i}")
          // mkWorkspaceBindings "ctrl-alt-shift" (i: [
            "move-node-to-workspace ${toString i}"
            "workspace ${toString i}"
          ]);

          move.binding = {
            esc = "mode main";
          }
          // mkAllDirectionBindings "" (d: "move ${d}")
          // mkWorkspaceBindings "" (i: [
            "move-node-to-workspace ${toString i}"
            "workspace ${toString i}"
            "mode main"
          ]);

          open.binding = {
            esc = "mode main";
            t = mkAppBinding "/Applications/Alacritty.app";
            b = mkAppBinding "/Applications/Firefox.app";
            s = mkAppBinding "/Applications/Slack.app";
            m = mkAppBinding "/Applications/Spotify.app";
            f = mkAppBinding "/System/Library/CoreServices/Finder.app";
          };

          service.binding = {
            esc = mkServiceAction "reload-config" "Config reloaded! Back to main mode.";
            p = [
              "exec-and-forget noti -t aerospace -m \"Disabled Aerospace\""
              "enable toggle"
            ];
            b =
              mkServiceActionWithCommand "exec-and-forget brew services restart borders" ""
                "Restarted borders! Back to main mode.";
            r = mkServiceAction "flatten-workspace-tree" "Reset layout tree! Back to main mode.";
            backspace = mkServiceAction "close-all-windows-but-current" "Closed all other windows! Back to main mode.";
          };
        };
      };
    };
  };
}
