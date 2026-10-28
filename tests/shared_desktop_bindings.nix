{
  lib,
  niriBindings,
  aerospaceBindings,
}:
let
  shared = import ../modules/desktop/shared-bindings.nix { inherit lib; };
  keys = map (b: "${if b.shift then "shift-" else ""}${b.key}") shared.bindings;
  find = key: shift: lib.findFirst (b: b.key == key && b.shift == shift) null shared.bindings;
  niriKey = b: "Mod+Ctrl+${lib.optionalString b.shift "Shift+"}${b.key}";
  macKey = b: "cmd-ctrl-${lib.optionalString b.shift "shift-"}${lib.toLower b.key}";
in
assert lib.length keys == lib.length (lib.unique keys);
assert (find "Left" false).niri == { focus-column-left = [ ]; };
assert (find "Left" true).aerospace == "move --boundaries all-monitors-outer-frame left";
assert (find "Up" true).aerospace == "move --boundaries all-monitors-outer-frame up";
assert (find "1" false).aerospace == "workspace 1";
assert
  (find "9" true).aerospace == [
    "move-node-to-workspace 9"
    "workspace 9"
  ];
assert (find "O" false).aerospace == null;
assert (find "R" false).aerospace == null;
assert lib.all (b: niriBindings.${niriKey b}.action == b.niri) shared.bindings;
assert lib.all (b: aerospaceBindings.${macKey b} == b.aerospace) (
  lib.filter (b: b.aerospace != null) shared.bindings
);
assert aerospaceBindings.cmd-ctrl-r != "";
assert aerospaceBindings.ctrl-alt-1 == "workspace 1";
assert shared.screenshots.niri.Print.action.screenshot == [ ];
assert shared.screenshots.niri."Ctrl+Print".action.screenshot-screen == [ ];
assert shared.screenshots.niri."Alt+Print".action.screenshot-window == [ ];
assert shared.screenshots.macos.symbolicHotkey == "30";
assert
  shared.screenshots.macos.parameters == [
    65535
    105
    8388608
  ];
assert niriBindings.Print.action == shared.screenshots.niri.Print.action;
assert niriBindings."Ctrl+Print".action == shared.screenshots.niri."Ctrl+Print".action;
assert niriBindings."Alt+Print".action == shared.screenshots.niri."Alt+Print".action;
true
