# Desktop controls

Shared Niri and AeroSpace bindings live in `modules/desktop/shared-bindings.nix`.
The window key is Super on Linux. On macOS it is Ctrl for arrows, digits and
Page keys, and Command+Control for letters, because Ctrl+letter belongs to the
shell, editors and text fields. No modifier is remapped, so each system keeps
its own app key (Command on macOS, Ctrl on Linux).

Arrows focus and Shift+arrows move, crossing monitor edges, so there is no
separate monitor layer. Numbers 1–9 select a workspace, Page Up/Down step
through them, and Shift moves the window there and follows it.

| Action | Linux | macOS |
|---|---|---|
| Launcher | Super+Space | Command+Space (Spotlight) |
| Terminal, browser | Super+T, Super+B | Command+Control+T, B |
| Close window | Super+Q | Command+Q (quits the app with its last window) |
| Lock | Super+Esc | Command+Esc |
| Window switcher | Super+Tab (niri default) | Command+Tab |
| Managed / native fullscreen | Super+F / Super+Shift+F | Command+Control+F / +Shift |
| Floating | Super+V | Command+Control+V |
| Tabbed (accordion) / tiles | Super+W / Super+E | Command+Control+W / E |
| Width, height (Shift) | Super+Minus/Equal | Command+Control+Minus/Equal |

Command+Q overrides the apps' own quit; Force Quit stays on Option+Command+Esc.
Command+Esc sends macOS's Control+Command+Q lock shortcut, so the first press
asks to let AeroSpace control System Events. Resize steps are points on
AeroSpace and percentages on Niri, and AeroSpace uses tree tiling rather than
Niri's scrolling columns.

Command+Control+L restores the AeroSpace app layout (macOS only). Linux alone
keeps Super+O for Overview, Super+Alt+C for the control center, Super+Shift+D
for dictation, Super+Shift+Space for the keyboard layout and Super+Shift+Esc to
release shortcuts an app has inhibited. Logout and power actions live in the
Noctalia launcher. Workspaces 1–9 are fixed, and kitty and the browser open on
workspace 1. The `desktop-bindings` check keeps both sides in step.

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

## Laptop parity

The `laptop-parity` check evaluates `sam@smoreswork` and `smores@smorespro`
and compares shell abbreviations, aliases, session variables and path, ssh
settings, git config keys, packages by name, user services (systemd units
against launchd agents, by name) and home activation steps; bindings stay with
`desktop-bindings`. Any difference must be listed in
`tests/laptop-parity-sanctioned.nix` as `category.name = "<inherent|work-policy>: reason"`
(`inherent` for platform, `work-policy` for employer or Sam's work choices), and an
entry that no longer differs fails the check, so delete it when the sides converge.
The failure names each item with both values; a new difference is either drift to
fix or one line to add there.
