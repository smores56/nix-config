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
          match = builtins.match ''[[:space:]]+(base[0-9A-Fa-f]+):[[:space:]]+"#([0-9a-fA-F]+)"'' line;
        in
        if match != null then
          {
            name = builtins.elemAt match 0;
            value = builtins.elemAt match 1;
          }
        else
          null;
      parsed = builtins.filter (x: x != null) (map parseLine lines);
    in
    builtins.listToAttrs parsed;

  darkColors = parseScheme "${pkgs.base16-schemes}/share/themes/${cfg.darkTheme.system}.yaml";
  lightColors = parseScheme "${pkgs.base16-schemes}/share/themes/${cfg.lightTheme.system}.yaml";

  fishColorsScript =
    colors: ''
      set -U fish_color_normal ${colors.base05}
      set -U fish_color_command ${colors.base0D}
      set -U fish_color_quote ${colors.base0B}
      set -U fish_color_redirection ${colors.base0C}
      set -U fish_color_end ${colors.base0C}
      set -U fish_color_error ${colors.base08}
      set -U fish_color_param ${colors.base05}
      set -U fish_color_comment ${colors.base03}
      set -U fish_color_selection --background=${colors.base02}
      set -U fish_color_search_match --background=${colors.base02}
      set -U fish_color_operator ${colors.base0C}
      set -U fish_color_escape ${colors.base0C}
      set -U fish_color_autosuggestion ${colors.base03}
      set -U fish_pager_color_progress ${colors.base03}
      set -U fish_pager_color_prefix ${colors.base0D}
      set -U fish_pager_color_completion ${colors.base05}
      set -U fish_pager_color_description ${colors.base03}
    '';

  zellijConfig =
    colors: ''
      default_shell "${cfg.shellPath}"
      ui {
        pane_frames {
          rounded_corners true
        }
      }
      session_serialization false
      show_startup_tips false
      themes {
        active {
          text_unselected {
            fg "#${colors.base05}"
            bg "#${colors.base01}"
          }
          text_selected {
            fg "#${colors.base05}"
            bg "#${colors.base04}"
          }
          ribbon_selected {
            fg "#${colors.base01}"
            bg "#${colors.base0E}"
          }
          ribbon_unselected {
            fg "#${colors.base01}"
            bg "#${colors.base05}"
          }
          table_title {
            fg "#${colors.base0E}"
            bg "#${colors.base00}"
          }
          table_cell_selected {
            fg "#${colors.base05}"
            bg "#${colors.base04}"
          }
          table_cell_unselected {
            fg "#${colors.base05}"
            bg "#${colors.base01}"
          }
          list_selected {
            fg "#${colors.base05}"
            bg "#${colors.base04}"
          }
          list_unselected {
            fg "#${colors.base05}"
            bg "#${colors.base01}"
          }
          frame_selected {
            fg "#${colors.base0E}"
            bg "#${colors.base00}"
          }
          frame_highlight {
            fg "#${colors.base08}"
            bg "#${colors.base00}"
          }
          exit_code_success {
            fg "#${colors.base0B}"
            bg "#${colors.base00}"
          }
          exit_code_error {
            fg "#${colors.base08}"
            bg "#${colors.base00}"
          }
        }
      }
      theme "active"
    '';

  darkFishColors = pkgs.writeText "dark-fish-colors.fish" (fishColorsScript darkColors);
  lightFishColors = pkgs.writeText "light-fish-colors.fish" (fishColorsScript lightColors);

  darkZellijConfig = pkgs.writeText "dark-zellij-config.kdl" (zellijConfig darkColors);
  lightZellijConfig = pkgs.writeText "light-zellij-config.kdl" (zellijConfig lightColors);

  darkModeHook = pkgs.writeShellScript "dark-mode-hook" ''
    IS_DARK="''${1:-}"
    if [ -z "$IS_DARK" ]; then
      # Fallback: detect from gsettings (defaults to dark on macOS/headless where gsettings is unavailable)
      MODE=$(${pkgs.glib}/bin/gsettings get org.gnome.desktop.interface color-scheme 2>/dev/null || echo "")
      if echo "$MODE" | grep -q "prefer-light"; then
        IS_DARK="false"
      else
        IS_DARK="true"
      fi
    fi
    if [ "$IS_DARK" = "false" ]; then
      HELIX_THEME="${cfg.lightTheme.helix}"
      LAZYGIT_LIGHT="true"
      FISH_COLORS="${lightFishColors}"
      ZELLIJ_CONFIG="${lightZellijConfig}"
    else
      HELIX_THEME="${cfg.darkTheme.helix}"
      LAZYGIT_LIGHT="false"
      FISH_COLORS="${darkFishColors}"
      ZELLIJ_CONFIG="${darkZellijConfig}"
    fi

    # Helix: update active theme and signal reload
    mkdir -p "$HOME/.config/helix/themes"
    echo "inherits = \"$HELIX_THEME\"" > "$HOME/.config/helix/themes/active.toml"
    ${pkgs.procps}/bin/pkill -USR1 hx 2>/dev/null || true

    # Lazygit: update theme for next launch
    mkdir -p "$HOME/.config/lazygit"
    cat > "$HOME/.config/lazygit/theme.yml" <<EOF
gui:
  theme:
    lightTheme: $LAZYGIT_LIGHT
EOF

    # Fish: update universal color variables (affects all running sessions)
    ${pkgs.fish}/bin/fish "$FISH_COLORS" 2>/dev/null || true

    # Zellij: copy config with matching theme (regular file, not symlink)
    # Zellij's file watcher detects the change and reloads live
    mkdir -p "$HOME/.config/zellij"
    cp "$ZELLIJ_CONFIG" "$HOME/.config/zellij/config.kdl"
    chmod 644 "$HOME/.config/zellij/config.kdl"
  '';
in
{
  config.dotfiles.darkModeHook = darkModeHook;

  config.home.packages = [
    (pkgs.writeShellScriptBin "theme-sync" ''
      exec ${darkModeHook} "$@"
    '')
  ];

  config.stylix = {
    enable = true;
    autoEnable = true;
    polarity = "dark";
    base16Scheme = "${pkgs.base16-schemes}/share/themes/${cfg.darkTheme.system}.yaml";
    image = ../../wallpapers/rocket-launch.png;

    fonts.monospace = {
      package = cfg.fontPackage;
      name = cfg.font;
    };

    cursor = lib.mkIf (cfg.displayManager != null) {
      package = pkgs.bibata-cursors;
      name = "Bibata-Modern-Classic";
      size = 24;
    };

    targets = {
      wezterm.enable = false;
      helix.enable = false;
      lazygit.enable = false;
      opencode.enable = false;
      fish.enable = false;
      zellij.enable = false;
    };
  };

  config.home.activation.seedThemeConfigs = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    ${darkModeHook} true
  '';
}
