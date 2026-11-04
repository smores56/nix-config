# Desktop controls

Shared Niri and AeroSpace bindings live in `modules/desktop/shared-bindings.nix`.
Use Super+Control on Linux and Command+Control on macOS; add Shift to move.
Arrows focus or move, numbers 1–9 select a workspace, and Shift+number moves
the current item to a workspace. AeroSpace follows the moved window; Niri
moves the column.

Both managers bind F for managed maximize/fullscreen, Shift+F for fullscreen,
V for floating, and Minus/Equal for width adjustment (with Shift for height).
These are approximations: AeroSpace Shift+F enters macOS native fullscreen,
and its resize increments are points rather than Niri's percentages. AeroSpace
uses tree tiling, not Niri's scrolling columns. Niri-only actions such as
Overview and column operations have no AeroSpace equivalent here.

T opens kitty, B the browser (Chrome on macOS, Firefox on Linux), D the launcher
(Spotlight on macOS) and Q closes the window. Arrows cross monitor edges; add
Option to focus a monitor and Option+Shift to move to one. W toggles tabbed
columns on Niri and accordion on AeroSpace, and Comma joins the next window.
Workspaces 1–9 are fixed, and kitty and the browser open on workspace 1.
The one-sided keys are listed in `modules/desktop/shared-bindings.nix`, and the
`desktop-bindings` check covers the rest on both.

Command+Control+L restores the AeroSpace app layout; 0 balances sizes and E
cycles tiles. The existing Control+Option workspace shortcuts remain available.
On Linux the original Super-only Niri bindings remain; monitor moves use
Super+Alt+Shift+arrows. Noctalia launcher, control-center, and lock shortcuts
remain in `modules/desktop/niri/keybinds.nix`. Applications or macOS may claim
some chords; Command+Control+arrows overlap Slack section navigation.

## Print Screen

ZMK `PSCRN` is a keyboard-page Print Screen key, which macOS receives as F13
on the tested board. Niri binds Print to its interactive screenshot tool,
Control+Print to screen capture and Alt+Print to window capture; macOS gets F13
for selected area, Control+F13 for screen and Option+F13 for the capture
toolbar (macOS has no direct window shortcut). Home Manager adds each missing
shortcut and leaves an already customized one alone, reporting it during
activation. Change a different keyboard's key in System Settings → Keyboard →
Keyboard Shortcuts → Screenshots.

Key repeat, scroll direction and scroll speed on macOS come from the same
constants as Niri's input settings, in `modules/desktop/shared-bindings.nix`.
