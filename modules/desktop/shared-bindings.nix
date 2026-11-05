{ lib }:
let
  apps = {
    brave = "com.brave.Browser";
    kitty = "net.kovidgoyal.kitty";
  };
  # niri's panel name; macOS keeps Spotlight on its native Cmd+Space.
  niriLauncher = "noctalia msg panel-toggle launcher";
  niriLock = "noctalia msg session lock";
  open = bundle: "exec-and-forget /usr/bin/open -b ${bundle}";
  # macOS has no lock command; its own Ctrl+Cmd+Q shortcut locks whatever the password delay is. Key
  # code 12 is Q on any layout, the timeout keeps an unanswered permission prompt from hanging the
  # bind, and a refused keystroke falls back to sleeping the display rather than doing nothing.
  macLock = "exec-and-forget /usr/bin/osascript -e 'with timeout of 5 seconds' -e 'tell application \"System Events\" to key code 12 using {control down, command down}' -e 'end timeout' || /usr/bin/pmset displaysleepnow";

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

  # Super alone is free on Linux. On macOS Ctrl alone takes only arrows, digits and Page keys, whose
  # losses are minor (kitty's Ctrl+Shift tab and scroll keys, Brave's Ctrl+Page tab keys); letters
  # need Cmd+Ctrl because Ctrl+letter belongs to the shell, editors and Cocoa text editing, and
  # Cmd+Q/Cmd+Esc mirror Super+Q/Super+Esc on purpose.
  macMods = {
    nav = "ctrl";
    letter = "cmd-ctrl";
    app = "cmd";
  };
  # niri and AeroSpace spell some keys differently.
  key = name: {
    niri = name;
    mac = lib.toLower name;
  };
  keys = {
    pageUp = {
      niri = "Page_Up";
      mac = "pageUp";
    };
    pageDown = {
      niri = "Page_Down";
      mac = "pageDown";
    };
    escape = {
      niri = "Escape";
      mac = "esc";
    };
  };

  # The platform-specific command sits beside the key because the two window managers do not share
  # a command vocabulary.
  bindWith = mods: k: shift: niri: aerospace: {
    inherit
      mods
      shift
      niri
      aerospace
      ;
    key = if builtins.isString k then key k else k;
  };
  nav = bindWith macMods.nav;
  letter = bindWith macMods.letter;
  app = bindWith macMods.app;
  niriKey = b: "Mod+${lib.optionalString b.shift "Shift+"}${b.key.niri}";
  macKey = b: "${b.mods}-${lib.optionalString b.shift "shift-"}${b.key.mac}";

  directions = [
    "left"
    "right"
    "up"
    "down"
  ];
  horizontal = dir: dir == "left" || dir == "right";
  arrow = dir: key (lib.toUpper (lib.substring 0 1 dir) + lib.substring 1 (-1) dir);
  crossMonitor = "--boundaries all-monitors-outer-frame";
  # niri's `-or-monitor` forms continue onto the neighbouring monitor at the edge, as the AeroSpace
  # boundary does, so neither side needs a separate monitor layer.
  focus = map (
    dir:
    nav (arrow dir) false {
      ${if horizontal dir then "focus-column-or-monitor-${dir}" else "focus-window-or-monitor-${dir}"} =
        [ ];
    } "focus ${crossMonitor} ${dir}"
  ) directions;
  move = map (
    dir:
    nav (arrow dir) true {
      ${if horizontal dir then "move-column-${dir}-or-to-monitor-${dir}" else "move-window-${dir}"} = [ ];
    } "move ${crossMonitor} ${dir}"
  ) directions;
  # Both follow the moved window: niri's move-to-workspace focuses it by default.
  moveAndFollow = target: [
    "move-node-to-workspace ${target}"
    "workspace ${target}"
  ];
  # By name, not index: workspaces are pinned to different monitors, where an index is per monitor.
  workspaces = lib.concatMap (
    i:
    let
      n = toString i;
    in
    [
      (nav n false { focus-workspace = n; } "workspace ${n}")
      (nav n true { move-column-to-workspace = n; } (moveAndFollow n))
    ]
  ) (lib.range 1 9);
  # niri stacks workspaces vertically per monitor; AeroSpace's prev/next walk the same order.
  workspaceSteps =
    lib.concatMap
      (
        {
          k,
          niriDir,
          macDir,
        }:
        [
          (nav k false { "focus-workspace-${niriDir}" = [ ]; } "workspace ${macDir}")
          (nav k true { "move-column-to-workspace-${niriDir}" = [ ]; } (moveAndFollow macDir))
        ]
      )
      [
        {
          k = keys.pageUp;
          niriDir = "up";
          macDir = "prev";
        }
        {
          k = keys.pageDown;
          niriDir = "down";
          macDir = "next";
        }
      ];
  resizes =
    lib.concatMap
      (
        { k, sign }:
        [
          (letter k false {
            set-column-width = "${sign}${toString resize.percent}%";
          } "resize width ${sign}${toString resize.points}")
          (letter k true {
            set-window-height = "${sign}${toString resize.percent}%";
          } "resize height ${sign}${toString resize.points}")
        ]
      )
      [
        {
          k = "Minus";
          sign = "-";
        }
        {
          k = "Equal";
          sign = "+";
        }
      ];
in
{
  inherit
    apps
    gaps
    input
    niriKey
    macKey
    niriLauncher
    niriLock
    ;

  # Chords with no niri counterpart: restoring the AeroSpace app layout.
  macOnly = [ "cmd-ctrl-l" ];

  bindings =
    focus
    ++ move
    ++ workspaces
    ++ workspaceSteps
    ++ resizes
    ++ [
      (letter "T" false { spawn = [ "kitty" ]; } (open apps.kitty))
      (letter "B" false { spawn = [ "brave-origin" ]; } (open apps.brave))
      # AeroSpace's plain close never quits, which would leave windowless apps running.
      (app "Q" false { close-window = [ ]; } "close --quit-if-last-window")
      (app keys.escape false { spawn-sh = niriLock; } macLock)
      (letter "F" false { maximize-column = [ ]; } "fullscreen")
      (letter "F" true { fullscreen-window = [ ]; } "macos-native-fullscreen")
      (letter "V" false { toggle-window-floating = [ ]; } "layout floating tiling")
      (letter "W" false { set-column-display = "tabbed"; } "layout accordion horizontal vertical")
      (letter "E" false { set-column-display = "normal"; } "layout tiles horizontal vertical")
    ];

  # ZMK PSCRN is the keyboard-page Print Screen usage; macOS mapped the board to F13 (virtual key code 105).
  # The macOS parameters are [ascii 65535, key code, modifier mask]; 8388608 marks a function key,
  # 262144 adds Control and 524288 Option. Bare is the whole screen, Ctrl an area, Alt/Option the
  # menu: niri has no capture menu, so window capture stands in for it.
  screenshots = {
    niri = {
      Print.action.screenshot-screen = [ ];
      "Ctrl+Print".action.screenshot = [ ];
      "Alt+Print".action.screenshot-window = [ ];
    };
    macos = [
      # screen to file
      {
        symbolicHotkey = "28";
        parameters = [
          65535
          105
          8388608
        ];
      }
      # area to file
      {
        symbolicHotkey = "30";
        parameters = [
          65535
          105
          (8388608 + 262144)
        ];
      }
      # the capture toolbar
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
