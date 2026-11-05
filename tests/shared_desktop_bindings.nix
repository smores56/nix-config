{
  lib,
  niriBindings,
  aerospaceBindings,
}:
let
  shared = import ../modules/desktop/shared-bindings.nix { inherit lib; };
  niriKeys = map shared.niriKey shared.bindings;
  sharedMacKeys = map shared.macKey shared.bindings;
  niriAction = chord: niriBindings.${chord}.action;
  crossMonitor = "--boundaries all-monitors-outer-frame";
in
# Every shared chord is defined once and bound on both managers.
assert lib.length niriKeys == lib.length (lib.unique niriKeys);
assert lib.all (b: b.niri != null && b.aerospace != null) shared.bindings;
# AeroSpace binds exactly the shared chords plus the Mac-only ones, so no stale layer survives.
assert
  lib.sort lib.lessThan (lib.attrNames aerospaceBindings)
  == lib.sort lib.lessThan (sharedMacKeys ++ shared.macOnly);
# keybinds.nix merges the shared chords with unionOfDisjoint, so forcing its binds proves no local
# bind reuses one (the shared one would otherwise silently win).
assert builtins.isAttrs
  (import ../modules/desktop/niri/keybinds.nix {
    inherit lib;
  }).programs.niri.settings.binds;
# Both managers read every shared binding back out of the built configurations.
assert lib.all (b: niriAction (shared.niriKey b) == b.niri) shared.bindings;
assert lib.all (b: aerospaceBindings.${shared.macKey b} == b.aerospace) shared.bindings;

# Navigation: the window key alone, Shift to move.
assert niriAction "Mod+Left" == { focus-column-or-monitor-left = [ ]; };
assert niriAction "Mod+Shift+Left" == { move-column-left-or-to-monitor-left = [ ]; };
assert niriAction "Mod+Shift+Down" == { move-window-down = [ ]; };
assert aerospaceBindings.ctrl-left == "focus ${crossMonitor} left";
assert aerospaceBindings.ctrl-shift-up == "move ${crossMonitor} up";
assert niriAction "Mod+1" == { focus-workspace = "1"; };
assert niriAction "Mod+Shift+9" == { move-column-to-workspace = "9"; };
assert aerospaceBindings.ctrl-1 == "workspace 1";
assert
  aerospaceBindings.ctrl-shift-9 == [
    "move-node-to-workspace 9"
    "workspace 9"
  ];
assert niriAction "Mod+Page_Up" == { focus-workspace-up = [ ]; };
assert niriAction "Mod+Shift+Page_Down" == { move-column-to-workspace-down = [ ]; };
assert aerospaceBindings.ctrl-pageUp == "workspace prev";
assert
  aerospaceBindings.ctrl-shift-pageDown == [
    "move-node-to-workspace next"
    "workspace next"
  ];

# Launching, closing and locking.
assert niriAction "Mod+Space" == { spawn-sh = shared.niriLauncher; };
assert niriAction "Mod+T" == { spawn = [ "kitty" ]; };
assert niriAction "Mod+B" == { spawn = [ "brave-origin" ]; };
assert lib.hasInfix shared.apps.kitty aerospaceBindings.cmd-ctrl-t;
assert lib.hasInfix shared.apps.brave aerospaceBindings.cmd-ctrl-b;
assert niriAction "Mod+Q" == { close-window = [ ]; };
assert aerospaceBindings.cmd-q == "close --quit-if-last-window";
assert niriAction "Mod+Escape" == { spawn-sh = shared.niriLock; };
assert
  lib.hasInfix "key code 12 using {control down, command down}" aerospaceBindings.cmd-esc
  && lib.hasSuffix "|| /usr/bin/pmset displaysleepnow" aerospaceBindings.cmd-esc;

# Window state and layout.
assert niriAction "Mod+F" == { maximize-column = [ ]; };
assert aerospaceBindings.cmd-ctrl-shift-f == "macos-native-fullscreen";
assert niriAction "Mod+W" == { set-column-display = "tabbed"; };
assert niriAction "Mod+E" == { set-column-display = "normal"; };
assert aerospaceBindings.cmd-ctrl-w == "layout accordion horizontal vertical";
assert aerospaceBindings.cmd-ctrl-e == "layout tiles horizontal vertical";
assert
  lib.hasPrefix "exec-and-forget /nix/store/" aerospaceBindings.cmd-ctrl-l
  && lib.hasSuffix "-aerospace-layout-apply" aerospaceBindings.cmd-ctrl-l;

# Linux-only chords that stay, and retired ones that must not come back.
assert niriAction "Mod+O" == { toggle-overview = [ ]; };
assert niriAction "Super+Alt+C" == { spawn-sh = "noctalia msg panel-toggle control-center"; };
assert niriAction "Mod+Shift+Space" == { switch-layout = "prev"; };
assert niriBindings ? "Mod+Shift+D";
# Inhibiting clients must not swallow the chord that takes shortcuts back from them.
assert
  !niriBindings."Mod+Shift+Escape".allow-inhibiting
  && niriAction "Mod+Shift+Escape" == { toggle-keyboard-shortcuts-inhibit = [ ]; };
assert lib.all (k: !(niriBindings ? ${k})) [
  "Mod+D"
  "Mod+Ctrl+Left"
  "Mod+Alt+Shift+Left"
  "Mod+Comma"
  "Mod+Shift+E"
  "Ctrl+Alt+Delete"
];

assert shared.screenshots.niri.Print.action.screenshot == [ ];
assert
  lib.all (s: s.parameters != [ ]) shared.screenshots.macos
  && lib.length shared.screenshots.macos == 3;
assert lib.all (k: niriBindings.${k}.action == shared.screenshots.niri.${k}.action) (
  lib.attrNames shared.screenshots.niri
);
true
