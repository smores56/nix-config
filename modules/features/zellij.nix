_: {
  programs.zellij = {
    enable = true;

    settings = {
      show_startup_tips = false;
      session_serialization = false;
      # Stylix writes themes/stylix.kdl with a theme named `default`; zellij
      # merges the user theme dir over its built-ins, so this picks it up.
      theme = "default";
    };

    extraConfig = ''
      keybinds {
        // ── Normal mode: Ctrl+Alt for all primary actions ─────────────
        normal {
          // Free Alt+arrows for terminal apps (maki word-jump, readline, etc.)
          unbind "Alt Left" "Alt Right" "Alt Up" "Alt Down" "Ctrl q"

          // Pane management
          bind "Ctrl Alt Left"  { MoveFocusOrTab "Left"; }
          bind "Ctrl Alt Right" { MoveFocusOrTab "Right"; }
          bind "Ctrl Alt Down"  { MoveFocus "Down"; }
          bind "Ctrl Alt Up"    { MoveFocus "Up"; }
        }
      }
    '';
  };
}
