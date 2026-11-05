{
  lib,
  niriBindings,
  aerospaceBindings,
}:
let
  shared = import ../modules/desktop/shared-bindings.nix { inherit lib; };
  id = b: "${lib.optionalString b.alt "alt-"}${lib.optionalString b.shift "shift-"}${b.key}";
  keys = map id shared.bindings;
  find =
    key: shift: lib.findFirst (b: b.key == key && b.shift == shift && !b.alt) null shared.bindings;
  findAlt =
    key: shift: lib.findFirst (b: b.key == key && b.shift == shift && b.alt) null shared.bindings;
  oneSided = b: lib.elem (id b) shared.oneSided;
  macKeys = lib.filter (lib.hasPrefix "cmd-ctrl-") (lib.attrNames aerospaceBindings);
  sharedMacKeys = map shared.macKey (lib.filter (b: b.aerospace != null) shared.bindings);
  macOnlyKeys = map (k: "cmd-ctrl-${lib.toLower k}") shared.macOnly;
in
# Every shared action is bound on both managers unless it is listed as one-sided.
assert lib.length keys == lib.length (lib.unique keys);
assert lib.all (b: oneSided b || (b.niri != null && b.aerospace != null)) shared.bindings;
assert lib.all (b: !(oneSided b) || b.aerospace == null) shared.bindings;
assert lib.all (b: b.niri != null) shared.bindings;
# AeroSpace's Cmd+Ctrl chords come only from the shared list plus the reserved Mac-only keys, and the
# reserved keys are not shared, so a key can never mean different things on the two machines.
assert lib.sort lib.lessThan macKeys == lib.sort lib.lessThan (sharedMacKeys ++ macOnlyKeys);
assert lib.all (k: !(lib.elem k sharedMacKeys)) macOnlyKeys;
assert
  lib.hasPrefix "exec-and-forget /nix/store/" aerospaceBindings.cmd-ctrl-l
  && lib.hasSuffix "-aerospace-layout-apply" aerospaceBindings.cmd-ctrl-l;
# keybinds.nix merges the shared chords with unionOfDisjoint, so forcing its binds proves no local
# bind reuses one (the shared one would otherwise silently win).
assert builtins.isAttrs
  (import ../modules/desktop/niri/keybinds.nix {
    inherit lib;
    config = { };
  }).programs.niri.settings.binds;
assert lib.all (k: niriBindings ? ${k}) (
  map shared.niriKey (lib.filter (b: b.niri != null) shared.bindings)
);
# Launchers, monitors and layout actions.
assert (find "T" false).niri == { spawn = [ "kitty" ]; };
assert (find "B" false).niri == { spawn = [ "firefox" ]; };
assert lib.hasInfix shared.apps.chrome (find "B" false).aerospace;
assert lib.hasInfix shared.apps.kitty (find "T" false).aerospace;
assert (find "Q" false).aerospace == "close";
assert (find "D" false).niri == { spawn-sh = shared.niriLauncher; };
assert (find "Left" false).niri == { focus-column-or-monitor-left = [ ]; };
assert (find "Left" false).aerospace == "focus --boundaries all-monitors-outer-frame left";
assert (find "Left" true).aerospace == "move --boundaries all-monitors-outer-frame left";
assert (find "Down" true).niri == { move-window-down = [ ]; };
assert (findAlt "Right" false).aerospace == "focus-monitor right";
assert (findAlt "Right" true).aerospace == "move-node-to-monitor right";
assert (findAlt "Right" true).niri == { move-column-to-monitor-right = [ ]; };
assert (find "W" false).aerospace == "layout accordion horizontal vertical";
assert (find "Comma" false).aerospace == "join-with right";
assert (find "1" false).niri == { focus-workspace = "1"; };
assert
  (find "9" true).aerospace == [
    "move-node-to-workspace 9"
    "workspace 9"
  ];
# Both managers read every shared binding back out of the built configurations.
assert lib.all (b: niriBindings.${shared.niriKey b}.action == b.niri) shared.bindings;
assert lib.all (b: aerospaceBindings.${shared.macKey b} == b.aerospace) (
  lib.filter (b: b.aerospace != null) shared.bindings
);
assert aerospaceBindings.ctrl-alt-1 == "workspace 1";
assert shared.screenshots.niri.Print.action.screenshot == [ ];
assert shared.screenshots.niri."Ctrl+Print".action.screenshot-screen == [ ];
assert shared.screenshots.niri."Alt+Print".action.screenshot-window == [ ];
assert
  lib.all (s: s.parameters != [ ]) shared.screenshots.macos
  && lib.length shared.screenshots.macos == 3;
assert niriBindings.Print.action == shared.screenshots.niri.Print.action;
assert niriBindings."Ctrl+Print".action == shared.screenshots.niri."Ctrl+Print".action;
assert niriBindings."Alt+Print".action == shared.screenshots.niri."Alt+Print".action;
true
