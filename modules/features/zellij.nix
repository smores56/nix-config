{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.dotfiles;

  parseScheme =
    file:
    let
      content = builtins.readFile file;
      lines = lib.splitString "\n" content;
      parseLine =
        line:
        let
          match = builtins.match ''[[:space:]]+(base[0-9A-Fa-f]+):[[:space:]]+"#([0-9a-fA-F]+)".*'' line;
        in
        if match != null then
          {
            name = builtins.elemAt match 0;
            value = builtins.elemAt match 1;
          }
        else
          null;
      parsed = builtins.filter (x: x != null) (map parseLine lines);
      result = builtins.listToAttrs parsed;
    in
    assert
      builtins.length parsed >= 16
      || throw "parseScheme: expected at least 16 base16 colors in ${file}, got ${toString (builtins.length parsed)}";
    result;

  darkColors = parseScheme "${pkgs.base16-schemes}/share/themes/${cfg.darkTheme.system}.yaml";
  lightColors = parseScheme "${pkgs.base16-schemes}/share/themes/${cfg.lightTheme.system}.yaml";

  zellijBlock =
    {
      base,
      background,
      emphasis_0,
      emphasis_1,
      emphasis_2,
      emphasis_3,
    }:
    {
      inherit
        base
        background
        emphasis_0
        emphasis_1
        emphasis_2
        emphasis_3
        ;
    };

  zellijTheme =
    colors:
    let
      c = lib.mapAttrs (_: v: "#${v}") colors;
      unselected = zellijBlock {
        base = c.base05;
        background = c.base01;
        emphasis_0 = c.base09;
        emphasis_1 = c.base0C;
        emphasis_2 = c.base0B;
        emphasis_3 = c.base0F;
      };
      selected = zellijBlock {
        base = c.base05;
        background = c.base04;
        emphasis_0 = c.base09;
        emphasis_1 = c.base0C;
        emphasis_2 = c.base0B;
        emphasis_3 = c.base0F;
      };
      title = zellijBlock {
        base = c.base0E;
        background = c.base00;
        emphasis_0 = c.base09;
        emphasis_1 = c.base0C;
        emphasis_2 = c.base0B;
        emphasis_3 = c.base0F;
      };
    in
    {
      text_unselected = unselected;
      text_selected = selected;
      ribbon_selected = zellijBlock {
        base = c.base01;
        background = c.base0E;
        emphasis_0 = c.base08;
        emphasis_1 = c.base09;
        emphasis_2 = c.base0F;
        emphasis_3 = c.base0D;
      };
      ribbon_unselected = zellijBlock {
        base = c.base01;
        background = c.base05;
        emphasis_0 = c.base08;
        emphasis_1 = c.base05;
        emphasis_2 = c.base0D;
        emphasis_3 = c.base0F;
      };
      table_title = title;
      table_cell_selected = selected;
      table_cell_unselected = unselected;
      list_selected = selected;
      list_unselected = unselected;
      frame_selected = zellijBlock {
        base = c.base0E;
        background = c.base00;
        emphasis_0 = c.base09;
        emphasis_1 = c.base0C;
        emphasis_2 = c.base0F;
        emphasis_3 = c.base00;
      };
      frame_highlight = zellijBlock {
        base = c.base08;
        background = c.base00;
        emphasis_0 = c.base0F;
        emphasis_1 = c.base09;
        emphasis_2 = c.base09;
        emphasis_3 = c.base09;
      };
      exit_code_success = zellijBlock {
        base = c.base0B;
        background = c.base00;
        emphasis_0 = c.base0C;
        emphasis_1 = c.base01;
        emphasis_2 = c.base0F;
        emphasis_3 = c.base0D;
      };
      exit_code_error = zellijBlock {
        base = c.base08;
        background = c.base00;
        emphasis_0 = c.base0A;
        emphasis_1 = c.base00;
        emphasis_2 = c.base00;
        emphasis_3 = c.base00;
      };
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

  zellij-src = pkgs.fetchFromGitHub {
    owner = "zellij-org";
    repo = "zellij";
    rev = "914953758357024d3c1aeaa496bfe8df906f8416";
    hash = "sha256-hVtpZ43KbdmlyY6Ms98ZemamNlz0wsYv417WiR/A9jU=";
  };

  # TODO: drop override once zellij ≥0.45.0 lands in nixpkgs (~Sep 2026)
  zellij-pkg = pkgs.zellij.overrideAttrs (_: {
    version = "0.45.0-pre";
    src = zellij-src;
    cargoDeps = pkgs.rustPlatform.fetchCargoVendor {
      src = zellij-src;
      hash = "sha256-7bRnzQ2BqYfMH8NEBT8uwDkXzeUyhni28eqRGCGjvOc=";
    };
    doInstallCheck = false;
  });

  baseIsDark = cfg.polarity != "light";
in
{
  programs.zellij = {
    enable = true;
    enableFishIntegration = false;
    package = zellij-pkg;
    settings = {
      default_shell = cfg.shellPath;
      ui.pane_frames.rounded_corners = true;
      session_serialization = false;
      show_startup_tips = false;
      theme = if baseIsDark then "dark" else "light";
      theme_dark = "dark";
      theme_light = "light";
      themes.dark = zellijTheme darkColors;
      themes.light = zellijTheme lightColors;
    };
  };
}
