{
  config,
  lib,
  pkgs,
  ...
}:
let
  enabled = config.dotfiles.windowManager == "aerospace";

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

  # Patterns are case-insensitive regexes over monitor names. A pinned
  # workspace falls back to the built-in display when its monitor is absent
  # (first resolving pattern wins), so undocking collapses onto the laptop.
  monitors = {
    main = "^dell u3425we";
    side = "^27e6qca";
    builtIn = "^built-in";
  };
  workspaces = {
    work = "1";
    comms = "2";
  };
  pinnedWorkspaces = {
    ${workspaces.work} = monitors.main;
    ${workspaces.comms} = monitors.side;
  };

  # Pinned apps by bundle id; anything not listed is never moved by layouts.
  apps = {
    chrome = "com.google.Chrome";
    kitty = "net.kovidgoyal.kitty";
    slack = "com.tinyspeck.slackmacgap";
    mail = "com.apple.mail";
    calendar = "com.apple.iCal";
  };
  workLayout = {
    name = workspaces.work;
    layout = "h_tiles";
    children = [
      apps.chrome
      apps.kitty
    ];
  };
  # Consumed by aerospace_layout.py; a nested two-app list becomes a split
  # perpendicular to its workspace root. focus = null restores prior focus.
  layoutSpec = {
    builtInMonitor = monitors.builtIn;
    layouts = {
      docked = {
        focus = null;
        workspaces = [
          workLayout
          {
            name = workspaces.comms;
            layout = "h_tiles";
            children = [
              apps.slack
              [
                apps.mail
                apps.calendar
              ]
            ];
          }
        ];
      };
      laptop = {
        focus = workspaces.work;
        workspaces = [
          workLayout
          {
            name = workspaces.comms;
            layout = "h_accordion";
            children = [
              apps.slack
              apps.mail
              apps.calendar
            ];
          }
        ];
      };
    };
  };
  # Parsed at build time so a malformed spec fails the switch, not a keypress.
  layoutSpecFile =
    pkgs.runCommand "aerospace-layout.json"
      {
        spec = builtins.toJSON layoutSpec;
        passAsFile = [ "spec" ];
      }
      ''
        ${pkgs.python3}/bin/python3 -I ${./aerospace_layout.py} check "$specPath"
        cp "$specPath" "$out"
      '';
  # exec-and-forget's PATH lacks the nix profile, so pin every path here.
  aerospaceLayout = pkgs.writeShellScriptBin "aerospace-layout" ''
    export AEROSPACE_LAYOUT_SPEC=${layoutSpecFile}
    export AEROSPACE_BIN=${config.programs.aerospace.package}/bin/aerospace
    exec ${pkgs.python3}/bin/python3 -I ${./aerospace_layout.py} "$@"
  '';
  # exec-and-forget discards output, so report the outcome as a notification.
  # stdout carries the applied mode; stderr lists problems, if any.
  layoutAction =
    mode:
    let
      apply = pkgs.writeShellScript "aerospace-layout-${mode}" ''
        if out=$(${aerospaceLayout}/bin/aerospace-layout ${mode} 2>&1); then
          ${pkgs.noti}/bin/noti -t aerospace -m "Applied $out layout"
        else
          ${pkgs.noti}/bin/noti -t aerospace -m "Layout problems: $out"
        fi
      '';
    in
    "exec-and-forget ${apply}";

  # Without all-monitors-outer-frame, focus and move stop at the current
  # monitor's edge instead of continuing onto the adjacent monitor.
  crossMonitor = "--boundaries all-monitors-outer-frame";

  mkAppBinding = app: [
    "exec-and-forget open -a ${app}"
    "mode main"
  ];

  mkServiceAction =
    command: action: message:
    (if command != null then [ command ] else [ ])
    ++ (if action == "" then [ ] else [ action ])
    ++ [
      "exec-and-forget noti -t aerospace -m \"${message}\""
      "mode main"
    ];
in
{
  config = lib.mkIf enabled {
    home.packages = [
      pkgs.noti
      pkgs.jankyborders
      aerospaceLayout
    ];

    programs.aerospace = {
      enable = true;

      settings = {
        start-at-login = false;
        default-root-container-layout = "tiles";
        default-root-container-orientation = "auto";
        after-startup-command = [
          "layout tiles"
          (layoutAction "auto")
        ];
        # Keyboard focus can now cross monitors; keep the pointer with it so
        # scrolling targets the focused monitor. Lazy: no-op if already there.
        on-focused-monitor-changed = [ "move-mouse monitor-lazy-center" ];

        workspace-to-monitor-force-assignment = lib.mapAttrs (_: monitor: [
          monitor
          monitors.builtIn
        ]) pinnedWorkspaces;

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
          // mkAllDirectionBindings "cmd-ctrl" (d: "focus ${crossMonitor} ${d}")
          // mkAllDirectionBindings "cmd-ctrl-shift" (d: "move ${crossMonitor} ${d}")
          // mkWorkspaceBindings "ctrl-alt" (i: "workspace ${toString i}")
          // mkWorkspaceBindings "ctrl-alt-shift" (i: [
            "move-node-to-workspace ${toString i}"
            "workspace ${toString i}"
          ]);

          move.binding = {
            esc = "mode main";
          }
          // mkAllDirectionBindings "" (d: "move ${crossMonitor} ${d}")
          // mkWorkspaceBindings "" (i: [
            "move-node-to-workspace ${toString i}"
            "workspace ${toString i}"
            "mode main"
          ]);

          open.binding = {
            esc = "mode main";
            t = mkAppBinding "/Applications/WezTerm.app";
            b = mkAppBinding "/Applications/Firefox.app";
            s = mkAppBinding "/Applications/Slack.app";
            m = mkAppBinding "/Applications/Spotify.app";
            f = mkAppBinding "/System/Library/CoreServices/Finder.app";
          };

          service.binding = {
            esc = mkServiceAction null "reload-config" "Config reloaded! Back to main mode.";
            d = [
              (layoutAction "docked")
              "mode main"
            ];
            l = [
              (layoutAction "laptop")
              "mode main"
            ];
            p = [
              "exec-and-forget noti -t aerospace -m \"Disabled Aerospace\""
              "enable toggle"
            ];
            b =
              mkServiceAction "exec-and-forget brew services restart borders" ""
                "Restarted borders! Back to main mode.";
            r = mkServiceAction null "flatten-workspace-tree" "Reset layout tree! Back to main mode.";
            backspace =
              mkServiceAction null "close-all-windows-but-current"
                "Closed all other windows! Back to main mode.";
          };
        };
      };
    };
  };
}
