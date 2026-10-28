# Desktop controls

Shared Niri and AeroSpace bindings live in `modules/desktop/shared-bindings.nix`.
Use Super+Control on Linux and Command+Control on macOS; add Shift to move.
Arrows focus or move, numbers 1–9 select a workspace, and Shift+number moves
the current item to a workspace. AeroSpace follows the moved window; Niri
moves the column. AeroSpace can cross monitor boundaries with arrows, whereas
Niri's shared horizontal controls operate on columns.

Both managers bind F for managed maximize/fullscreen, Shift+F for fullscreen,
V for floating, and Minus/Equal for width adjustment (with Shift for height).
These are approximations: AeroSpace Shift+F enters macOS native fullscreen,
and its resize increments are points rather than Niri's percentages. AeroSpace
uses tree tiling, not Niri's scrolling columns. Niri-only actions such as
Overview and column operations have no AeroSpace equivalent here.

On macOS Command+Control+R continues to restore the AeroSpace app layout;
Command+Control+0 balances sizes, E cycles tiles, and A cycles accordion
layouts. The existing Control+Option workspace shortcuts remain available.
On Linux the original Super-only Niri bindings remain; monitor moves use
Super+Alt+Shift+arrows. Noctalia launcher, control-center, and lock shortcuts
remain in `modules/desktop/niri/keybinds.nix`. Applications or macOS may claim
some chords; Command+Control+arrows overlap Slack section navigation.

## Print Screen

ZMK `PSCRN` is a keyboard-page Print Screen key. Niri binds Print to its
interactive screenshot tool, Control+Print to screen capture and Alt+Print to
window capture. The tested ZMK board reports PSCRN to macOS as F13. Home Manager
sets the native selected-area-to-file shortcut to F13 when that shortcut has
not already been customized; it leaves a different existing binding alone and
reports the conflict during activation. Other screenshot shortcuts are not
modified. If the setting was already customized, or a different keyboard
reports another key, change it in System Settings → Keyboard → Keyboard
Shortcuts → Screenshots.
