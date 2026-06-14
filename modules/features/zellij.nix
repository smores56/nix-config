{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.dotfiles;
  baseIsDark = cfg.polarity != "light";

  base16 = import ../lib/base16.nix { inherit lib; };
  darkColors = base16.parseScheme "${pkgs.base16-schemes}/share/themes/${cfg.darkTheme.system}.yaml";
  lightColors = base16.parseScheme "${pkgs.base16-schemes}/share/themes/${cfg.lightTheme.system}.yaml";

  # Convert base16 colors (no # prefix) to zellij theme format (with #).
  withHash = colors: lib.mapAttrs (_: v: "#${v}") colors;

  # Build a single theme section (e.g. text_selected, frame_highlight).
  section =
    c: base: bg: e0: e1: e2: e3:
    {
      base = c.${base};
      background = c.${bg};
      emphasis_0 = c.${e0};
      emphasis_1 = c.${e1};
      emphasis_2 = c.${e2};
      emphasis_3 = c.${e3};
    };

  # Build a complete zellij theme wrapped in the zellij `themes { }` block.
  mkTheme =
    name: c:
    let
      s = section c;
      body = {
        text_unselected = s "base05" "base01" "base09" "base0C" "base0B" "base0F";
        text_selected = s "base05" "base04" "base09" "base0C" "base0B" "base0F";
        ribbon_selected = s "base01" "base0E" "base08" "base09" "base0F" "base0D";
        ribbon_unselected = s "base01" "base05" "base08" "base05" "base0D" "base0F";
        table_title = s "base0E" "base00" "base09" "base0C" "base0B" "base0F";
        table_cell_selected = s "base05" "base04" "base09" "base0C" "base0B" "base0F";
        table_cell_unselected = s "base05" "base01" "base09" "base0C" "base0B" "base0F";
        list_selected = s "base05" "base04" "base09" "base0C" "base0B" "base0F";
        list_unselected = s "base05" "base01" "base09" "base0C" "base0B" "base0F";
        frame_selected = s "base0E" "base00" "base09" "base0C" "base0F" "base00";
        frame_highlight = s "base08" "base00" "base0F" "base09" "base09" "base09";
        exit_code_success = s "base0B" "base00" "base0C" "base01" "base0F" "base0D";
        exit_code_error = s "base08" "base00" "base0A" "base00" "base00" "base00";
        multiplayer_user_colors = {
          player_1 = c.base0F;
          player_2 = c.base0D;
          player_3 = c.base00;
          player_4 = c.base0A;
          player_5 = c.base0C;
          player_6 = c.base00;
          player_7 = c.base08;
          player_8 = c.base00;
          player_9 = c.base00;
          player_10 = c.base00;
        };
      };
    in
    {
      themes = {
        ${name} = body;
      };
    };

  darkTheme = mkTheme "stylix-dark" (withHash darkColors);
  lightTheme = mkTheme "stylix-light" (withHash lightColors);
in
{
  programs.zellij = {
    enable = true;

    settings = {
      show_startup_tips = false;
      theme = if baseIsDark then "stylix-dark" else "stylix-light";
    };

    themes = {
      "stylix-dark" = darkTheme;
      "stylix-light" = lightTheme;
    };

    extraConfig = ''
      keybinds {
        // ── Normal mode: Ctrl+Alt for all primary actions ─────────────
        normal {
          // Pane management
          bind "Ctrl Alt n" { NewPane; }
          bind "Ctrl Alt h" "Ctrl Alt Left"  { MoveFocusOrTab "Left"; }
          bind "Ctrl Alt l" "Ctrl Alt Right" { MoveFocusOrTab "Right"; }
          bind "Ctrl Alt j" "Ctrl Alt Down"  { MoveFocus "Down"; }
          bind "Ctrl Alt k" "Ctrl Alt Up"    { MoveFocus "Up"; }

          // Tab management
          bind "Ctrl Alt i" { GoToPreviousTab; }
          bind "Ctrl Alt o" { GoToNextTab; }
          bind "Ctrl Alt t" { NewTab; }
          bind "Ctrl Alt w" { CloseFocus; }

          // Floating / zoom
          bind "Ctrl Alt f" { ToggleFloatingPanes; }
          bind "Ctrl Alt z" { TogglePaneFrames; }

          // Mode switches
          bind "Ctrl Alt p" { SwitchToMode "pane"; }
          bind "Ctrl Alt r" { SwitchToMode "resize"; }
          bind "Ctrl Alt d" { SwitchToMode "move"; }
          bind "Ctrl Alt s" { SwitchToMode "scroll"; }
          bind "Ctrl Alt g" { SwitchToMode "locked"; }

          // Session
          bind "Ctrl Alt q" { Quit; }

          // Tab navigation
          bind "Ctrl Alt 1" { GoToTab 1; }
          bind "Ctrl Alt 2" { GoToTab 2; }
          bind "Ctrl Alt 3" { GoToTab 3; }
          bind "Ctrl Alt 4" { GoToTab 4; }
          bind "Ctrl Alt 5" { GoToTab 5; }
          bind "Ctrl Alt 6" { GoToTab 6; }
          bind "Ctrl Alt 7" { GoToTab 7; }
          bind "Ctrl Alt 8" { GoToTab 8; }
          bind "Ctrl Alt 9" { GoToTab 9; }
        }

        // ── Pane mode: vim-style movement, no modifier ────────────────
        pane {
          bind "h" "Left"  { MoveFocus "Left"; }
          bind "j" "Down"  { MoveFocus "Down"; }
          bind "k" "Up"    { MoveFocus "Up"; }
          bind "l" "Right" { MoveFocus "Right"; }
          bind "p"         { SwitchFocus; }
          bind "n"         { NewPane; }
          bind "w"         { CloseFocus; }
          bind "f"         { ToggleFloatingPanes; }
          bind "z"         { TogglePaneFrames; }
          bind "Tab"       { SwitchFocus; }
        }

        // ── Resize mode ────────────────────────────────────────────────
        resize {
          bind "h" "Left"  { Resize "Left"; }
          bind "j" "Down"  { Resize "Down"; }
          bind "k" "Up"    { Resize "Up"; }
          bind "l" "Right" { Resize "Right"; }
          bind "="         { Resize "Increase"; }
          bind "-"         { Resize "Decrease"; }
        }

        // ── Move mode ──────────────────────────────────────────────────
        move {
          bind "h" "Left"  { MovePane "Left"; }
          bind "j" "Down"  { MovePane "Down"; }
          bind "k" "Up"    { MovePane "Up"; }
          bind "l" "Right" { MovePane "Right"; }
          bind "n"         { NewPane; }
        }

        // ── Tab mode ───────────────────────────────────────────────────
        tab {
          bind "h" "Left"  { GoToPreviousTab; }
          bind "l" "Right" { GoToNextTab; }
          bind "i"         { MoveTab "Left"; }
          bind "o"         { MoveTab "Right"; }
          bind "1"         { GoToTab 1; }
          bind "2"         { GoToTab 2; }
          bind "3"         { GoToTab 3; }
          bind "4"         { GoToTab 4; }
          bind "5"         { GoToTab 5; }
          bind "6"         { GoToTab 6; }
          bind "7"         { GoToTab 7; }
          bind "8"         { GoToTab 8; }
          bind "9"         { GoToTab 9; }
          bind "t"         { NewTab; }
          bind "w"         { CloseFocus; }
        }

        // ── Scroll mode ────────────────────────────────────────────────
        scroll {
          bind "j" "Down"      { ScrollDown; }
          bind "k" "Up"        { ScrollUp; }
          bind "Ctrl f"        { PageScrollDown; }
          bind "Ctrl b"        { PageScrollUp; }
          bind "g"             { ScrollToTop; }
          bind "G"             { ScrollToBottom; }
        }

        // ── Locked mode: Ctrl+g to unlock ──────────────────────────────
        locked {
          bind "Ctrl g" { SwitchToMode "normal"; }
        }
      }
    '';
  };
}
