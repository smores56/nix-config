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
  section = c: base: bg: e0: e1: e2: e3: {
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
      session_serialization = false;
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
