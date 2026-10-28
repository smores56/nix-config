{ lib }:
let
  # The physical GUI+Control chord is the base on both systems. Keep the
  # platform-specific command here alongside the key, rather than pretending
  # the two window managers implement the same command vocabulary.
  bind = key: shift: niri: aerospace: {
    inherit
      key
      shift
      niri
      aerospace
      ;
  };
  simple =
    key: shift: niri: aerospace:
    bind key shift { ${niri} = [ ]; } aerospace;
  crossMonitor = "--boundaries all-monitors-outer-frame";
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
  focus = map (
    { key, dir }:
    simple key false (
      if dir == "left" || dir == "right" then "focus-column-${dir}" else "focus-window-${dir}"
    ) "focus ${crossMonitor} ${dir}"
  ) directions;
  move = map (
    { key, dir }:
    simple key true (
      if dir == "left" || dir == "right" then "move-column-${dir}" else "move-window-${dir}"
    ) "move ${crossMonitor} ${dir}"
  ) directions;
  workspaces = lib.concatMap (i: [
    (bind (toString i) false { focus-workspace = i; } "workspace ${toString i}")
    (bind (toString i) true
      {
        move-column-to-workspace = i;
      }
      [
        "move-node-to-workspace ${toString i}"
        "workspace ${toString i}"
      ]
    )
  ]) (lib.range 1 9);
in
{
  # Null marks Niri-only actions without a useful AeroSpace equivalent.
  bindings =
    focus
    ++ move
    ++ workspaces
    ++ [
      (simple "O" false "toggle-overview" null)
      (simple "F" false "maximize-column" "fullscreen")
      (simple "F" true "fullscreen-window" "macos-native-fullscreen")
      (simple "V" false "toggle-window-floating" "layout floating tiling")
      (simple "W" false "toggle-column-tabbed-display" null)
      (simple "R" false "switch-preset-column-width" null)
      (simple "R" true "switch-preset-column-width-back" null)
      (simple "C" false "center-column" null)
      (simple "Comma" false "consume-window-into-column" null)
      (simple "Period" false "expel-window-from-column" null)
      (simple "Home" false "focus-column-first" null)
      (simple "End" false "focus-column-last" null)
      (simple "Home" true "move-column-to-first" null)
      (simple "End" true "move-column-to-last" null)
      (bind "Minus" false { set-column-width = "-10%"; } "resize width -30")
      (bind "Equal" false { set-column-width = "+10%"; } "resize width +30")
      (bind "Minus" true { set-window-height = "-10%"; } "resize height -30")
      (bind "Equal" true { set-window-height = "+10%"; } "resize height +30")
    ];

  # ZMK PSCRN is the keyboard-page Print Screen usage. macOS mapped the actual
  # board to F13 (virtual key code 105) during the trial.
  screenshots = {
    niri = {
      Print.action.screenshot = [ ];
      "Ctrl+Print".action.screenshot-screen = [ ];
      "Alt+Print".action.screenshot-window = [ ];
    };
    macos = {
      # System Settings > Keyboard > Shortcuts > Screenshots: area to file.
      symbolicHotkey = "30";
      parameters = [
        65535
        105
        8388608
      ];
    };
  };
}
