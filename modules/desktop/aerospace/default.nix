{
  config,
  lib,
  pkgs,
  ...
}:
let
  noti = "${pkgs.noti}/bin/noti";

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

  # Patterns are case-insensitive regexes over monitor names; the first
  # connected one wins. Work prefers any external, so with one external plus
  # the open laptop, work takes the external and comms the laptop.
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
    ${workspaces.work} = [
      monitors.main
      monitors.side
      monitors.builtIn
    ];
    ${workspaces.comms} = [
      monitors.builtIn
      monitors.side
    ];
  };

  # Pinned apps by bundle id; anything not listed is never moved by layouts.
  apps = {
    chrome = "com.google.Chrome";
    kitty = "net.kovidgoyal.kitty";
    slack = "com.tinyspeck.slackmacgap";
    mail = "com.apple.mail";
    calendar = "com.apple.iCal";
  };
  # Consumed by aerospace_layout.py; a nested two-app list becomes a split
  # perpendicular to its workspace root. One layout serves docked and laptop:
  # undocked, both workspaces fall back to the built-in display.
  layoutSpec = {
    workspaces = [
      {
        name = workspaces.work;
        layout = "h_tiles";
        children = [
          apps.chrome
          apps.kitty
        ];
      }
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
  # Store paths keep the tool independent of exec-and-forget's PATH.
  aerospaceLayout = pkgs.writeShellScriptBin "aerospace-layout" ''
    export AEROSPACE_LAYOUT_SPEC=${layoutSpecFile}
    export AEROSPACE_BIN=${config.programs.aerospace.package}/bin/aerospace
    exec ${pkgs.python3}/bin/python3 -I ${./aerospace_layout.py} "$@"
  '';
  # exec-and-forget discards output, so surface problems as a notification;
  # success stays silent.
  applyLayout =
    let
      apply = pkgs.writeShellScript "aerospace-layout-apply" ''
        if ! out=$(${aerospaceLayout}/bin/aerospace-layout 2>&1); then
          ${noti} -t aerospace -m "Layout problems: $out"
        fi
      '';
    in
    "exec-and-forget ${apply}";

  # Without all-monitors-outer-frame, focus and move stop at the current
  # monitor's edge instead of continuing onto the adjacent monitor.
  crossMonitor = "--boundaries all-monitors-outer-frame";
in
{
  home.packages = [ aerospaceLayout ];

  programs.aerospace = {
    enable = true;

    settings = {
      config-version = 2;
      # Version 2 no longer infers persistent workspaces from the bindings;
      # keep 1-9 so empty pinned workspaces stay on their monitors.
      persistent-workspaces = map toString (lib.range 1 9);
      start-at-login = false;
      # Replacing PATH drops AeroSpace's Homebrew default, so keep it; the nix
      # profile lets bare tools in exec-and-forget resolve.
      exec = {
        env-vars.PATH = "${config.home.profileDirectory}/bin:/opt/homebrew/bin:/opt/homebrew/sbin:\${PATH}";
      };
      default-root-container-layout = "tiles";
      default-root-container-orientation = "auto";
      after-startup-command = [
        "layout tiles"
        applyLayout
      ];
      # Keyboard focus can now cross monitors; keep the pointer with it so
      # scrolling targets the focused monitor. Lazy: no-op if already there.
      on-focused-monitor-changed = [ "move-mouse monitor-lazy-center" ];

      workspace-to-monitor-force-assignment = pinnedWorkspaces;

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
          cmd-ctrl-minus = "resize smart -30";
          cmd-ctrl-equal = "resize smart +30";
          cmd-ctrl-0 = "balance-sizes";
          cmd-ctrl-e = "layout tiles horizontal vertical";
          cmd-ctrl-a = "layout accordion horizontal vertical";
          # r for restore; no macOS or app default claims cmd-ctrl-r.
          cmd-ctrl-r = applyLayout;
        }
        // mkAllDirectionBindings "cmd-ctrl" (d: "focus ${crossMonitor} ${d}")
        // mkAllDirectionBindings "cmd-ctrl-shift" (d: "move ${crossMonitor} ${d}")
        // mkWorkspaceBindings "ctrl-alt" (i: "workspace ${toString i}")
        // mkWorkspaceBindings "ctrl-alt-shift" (i: [
          "move-node-to-workspace ${toString i}"
          "workspace ${toString i}"
        ]);
      };
    };
  };
}
