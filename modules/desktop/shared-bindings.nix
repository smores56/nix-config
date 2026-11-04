{ lib }:
let
  apps = {
    chrome = "com.google.Chrome";
    kitty = "net.kovidgoyal.kitty";
  };
  # niri's panel name; AeroSpace has no panel, so macOS uses Spotlight.
  niriLauncher = "noctalia msg panel-toggle launcher";
  open = bundle: "exec-and-forget /usr/bin/open -b ${bundle}";

  # One definition per input device setting, so macOS defaults and niri's input block cannot drift.
  input = {
    repeatDelayMs = 200;
    repeatRate = 35;
    naturalScroll = false;
    scrollFactor = 0.5;
  };
  # Both window managers draw the same gap on the laptop panel; external monitors get the regular one.
  gaps = {
    compact = 6;
    regular = 12;
  };
  # niri resizes by percent and AeroSpace by points, so one step cannot serve both.
  resize = {
    percent = 10;
    points = 30;
  };

  # GUI+Control is the base chord on both systems; the platform-specific command sits beside the key
  # because the two window managers do not share a command vocabulary.
  bindWith = alt: key: shift: niri: aerospace: {
    inherit
      key
      shift
      alt
      niri
      aerospace
      ;
  };
  bind = bindWith false;
  simple =
    key: shift: niri: aerospace:
    bind key shift { ${niri} = [ ]; } aerospace;
  niriKey =
    b: "Mod+Ctrl+${lib.optionalString b.alt "Alt+"}${lib.optionalString b.shift "Shift+"}${b.key}";
  macKey =
    b:
    "cmd-ctrl-${lib.optionalString b.alt "alt-"}${lib.optionalString b.shift "shift-"}${lib.toLower b.key}";

  directions = [
    {
      key = "Left";
      dir = "left";
    }
    {
      key = "Right";
      dir = "right";
    }
    {
      key = "Up";
      dir = "up";
    }
    {
      key = "Down";
      dir = "down";
    }
  ];
  crossMonitor = "--boundaries all-monitors-outer-frame";
  horizontal = dir: dir == "left" || dir == "right";
  # niri's `-or-monitor` forms continue onto the neighbouring monitor at the edge, as the AeroSpace boundary does.
  focus = map (
    { key, dir }:
    simple key false (
      if horizontal dir then "focus-column-or-monitor-${dir}" else "focus-window-or-monitor-${dir}"
    ) "focus ${crossMonitor} ${dir}"
  ) directions;
  move = map (
    { key, dir }:
    simple key true (
      # niri has no vertical move-to-monitor form; Alt+Shift+arrows covers that.
      if horizontal dir then "move-column-${dir}-or-to-monitor-${dir}" else "move-window-${dir}"
    ) "move ${crossMonitor} ${dir}"
  ) directions;
  monitors = lib.concatMap (
    { key, dir }:
    [
      (bindWith true key false { "focus-monitor-${dir}" = [ ]; } "focus-monitor ${dir}")
      (bindWith true key true { "move-column-to-monitor-${dir}" = [ ]; } "move-node-to-monitor ${dir}")
    ]
  ) directions;
  # By name, not index: workspaces are pinned to different monitors, where an index is per monitor.
  workspaces = lib.concatMap (i: [
    (bind (toString i) false { focus-workspace = toString i; } "workspace ${toString i}")
    (bind (toString i) true
      {
        move-column-to-workspace = toString i;
      }
      [
        "move-node-to-workspace ${toString i}"
        "workspace ${toString i}"
      ]
    )
  ]) (lib.range 1 9);

  # Keys that exist on one window manager only, because the other has no such action.
  oneSided = [
    "O"
    "R"
    "shift-R"
    "C"
    "Period"
    "Home"
    "End"
    "shift-Home"
    "shift-End"
  ];
  # Cmd+Ctrl keys with no niri counterpart (balance, tile toggle, layout restore); reserved here so
  # no shared action can claim them.
  macOnly = [
    "0"
    "E"
    "L"
  ];
in
{
  inherit
    apps
    gaps
    input
    resize
    niriKey
    macKey
    niriLauncher
    oneSided
    macOnly
    ;

  bindings =
    focus
    ++ move
    ++ monitors
    ++ workspaces
    ++ [
      (bind "T" false { spawn = [ "kitty" ]; } (open apps.kitty))
      (bind "B" false { spawn = [ "firefox" ]; } (open apps.chrome))
      (bind "D" false { spawn-sh = niriLauncher; } "exec-and-forget /usr/bin/open -a Spotlight")
      (simple "Q" false "close-window" "close")
      (simple "O" false "toggle-overview" null)
      (simple "F" false "maximize-column" "fullscreen")
      (simple "F" true "fullscreen-window" "macos-native-fullscreen")
      (simple "V" false "toggle-window-floating" "layout floating tiling")
      (simple "W" false "toggle-column-tabbed-display" "layout accordion horizontal vertical")
      (simple "R" false "switch-preset-column-width" null)
      (simple "R" true "switch-preset-column-width-back" null)
      (simple "C" false "center-column" null)
      (simple "Comma" false "consume-window-into-column" "join-with right")
      (simple "Period" false "expel-window-from-column" null)
      (simple "Home" false "focus-column-first" null)
      (simple "End" false "focus-column-last" null)
      (simple "Home" true "move-column-to-first" null)
      (simple "End" true "move-column-to-last" null)
      (bind "Minus" false {
        set-column-width = "-${toString resize.percent}%";
      } "resize width -${toString resize.points}")
      (bind "Equal" false {
        set-column-width = "+${toString resize.percent}%";
      } "resize width +${toString resize.points}")
      (bind "Minus" true {
        set-window-height = "-${toString resize.percent}%";
      } "resize height -${toString resize.points}")
      (bind "Equal" true {
        set-window-height = "+${toString resize.percent}%";
      } "resize height +${toString resize.points}")
    ];

  # ZMK PSCRN is the keyboard-page Print Screen usage; macOS mapped the board to F13 (virtual key code 105).
  # The macOS parameters are [ascii 65535, key code, modifier mask]; 8388608 marks a function key.
  screenshots = {
    niri = {
      Print.action.screenshot = [ ];
      "Ctrl+Print".action.screenshot-screen = [ ];
      "Alt+Print".action.screenshot-window = [ ];
    };
    macos = [
      # area to file
      {
        symbolicHotkey = "30";
        parameters = [
          65535
          105
          8388608
        ];
      }
      # screen to file
      {
        symbolicHotkey = "28";
        parameters = [
          65535
          105
          (8388608 + 262144)
        ];
      }
      # the capture toolbar, where window capture lives: macOS has no direct window-capture shortcut
      {
        symbolicHotkey = "184";
        parameters = [
          65535
          105
          (8388608 + 524288)
        ];
      }
    ];
  };
}
