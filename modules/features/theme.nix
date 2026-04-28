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
    in
    builtins.listToAttrs parsed;

  darkColors = parseScheme "${pkgs.base16-schemes}/share/themes/${cfg.darkTheme.system}.yaml";
  lightColors = parseScheme "${pkgs.base16-schemes}/share/themes/${cfg.lightTheme.system}.yaml";

  fishColorsScript = colors: ''
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

  hexToRgb =
    hex:
    let
      hexDigits = {
        "0" = 0; "1" = 1; "2" = 2; "3" = 3; "4" = 4;
        "5" = 5; "6" = 6; "7" = 7; "8" = 8; "9" = 9;
        "a" = 10; "b" = 11; "c" = 12; "d" = 13; "e" = 14; "f" = 15;
        "A" = 10; "B" = 11; "C" = 12; "D" = 13; "E" = 14; "F" = 15;
      };
      hexByte = s: hexDigits.${builtins.substring 0 1 s} * 16 + hexDigits.${builtins.substring 1 1 s};
      r = hexByte (builtins.substring 0 2 hex);
      g = hexByte (builtins.substring 2 2 hex);
      b = hexByte (builtins.substring 4 2 hex);
    in
    "${toString r} ${toString g} ${toString b}";

  zellijBlock =
    {
      base,
      background,
      emphasis_0,
      emphasis_1,
      emphasis_2,
      emphasis_3,
    }:
    ''
          base ${hexToRgb base}
          background ${hexToRgb background}
          emphasis_0 ${hexToRgb emphasis_0}
          emphasis_1 ${hexToRgb emphasis_1}
          emphasis_2 ${hexToRgb emphasis_2}
          emphasis_3 ${hexToRgb emphasis_3}'';

  zellijConfig = colors:
    let
      c = colors;
      unselected = zellijBlock { base = c.base05; background = c.base01; emphasis_0 = c.base08; emphasis_1 = c.base0C; emphasis_2 = c.base0B; emphasis_3 = c.base0E; };
      selected = zellijBlock { base = c.base05; background = c.base04; emphasis_0 = c.base08; emphasis_1 = c.base0C; emphasis_2 = c.base0B; emphasis_3 = c.base0E; };
      title = zellijBlock { base = c.base0E; background = c.base00; emphasis_0 = c.base08; emphasis_1 = c.base0C; emphasis_2 = c.base0B; emphasis_3 = c.base0D; };
    in
    ''
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
          ${unselected}
        }
        text_selected {
          ${selected}
        }
        ribbon_selected {
          ${zellijBlock { base = c.base01; background = c.base0E; emphasis_0 = c.base08; emphasis_1 = c.base0C; emphasis_2 = c.base0B; emphasis_3 = c.base0D; }}
        }
        ribbon_unselected {
          ${zellijBlock { base = c.base01; background = c.base05; emphasis_0 = c.base08; emphasis_1 = c.base0C; emphasis_2 = c.base0B; emphasis_3 = c.base0E; }}
        }
        table_title {
          ${title}
        }
        table_cell_selected {
          ${selected}
        }
        table_cell_unselected {
          ${unselected}
        }
        list_selected {
          ${selected}
        }
        list_unselected {
          ${unselected}
        }
        frame_selected {
          ${title}
        }
        frame_highlight {
          ${zellijBlock { base = c.base08; background = c.base00; emphasis_0 = c.base0E; emphasis_1 = c.base0C; emphasis_2 = c.base0B; emphasis_3 = c.base0D; }}
        }
        exit_code_success {
          ${zellijBlock { base = c.base0B; background = c.base00; emphasis_0 = c.base08; emphasis_1 = c.base0C; emphasis_2 = c.base0E; emphasis_3 = c.base0D; }}
        }
        exit_code_error {
          ${zellijBlock { base = c.base08; background = c.base00; emphasis_0 = c.base0B; emphasis_1 = c.base0C; emphasis_2 = c.base0E; emphasis_3 = c.base0D; }}
        }
        multiplayer_user_colors {
          player_1 ${hexToRgb colors.base08}
          player_2 ${hexToRgb colors.base0B}
          player_3 ${hexToRgb colors.base0D}
          player_4 ${hexToRgb colors.base0E}
          player_5 ${hexToRgb colors.base0C}
          player_6 ${hexToRgb colors.base09}
          player_7 ${hexToRgb colors.base0A}
          player_8 ${hexToRgb colors.base0F}
          player_9 ${hexToRgb colors.base03}
          player_10 ${hexToRgb colors.base04}
        }
      }
    }
    theme "active"
  '';

  darkFishColors = pkgs.writeText "dark-fish-colors.fish" (fishColorsScript darkColors);
  lightFishColors = pkgs.writeText "light-fish-colors.fish" (fishColorsScript lightColors);

  darkZellijConfig = pkgs.writeText "dark-zellij-config.kdl" (zellijConfig darkColors);
  lightZellijConfig = pkgs.writeText "light-zellij-config.kdl" (zellijConfig lightColors);

  isOsx = cfg.displayManager == "osx";

  detectDarkMode =
    if isOsx then
      ''
        MODE=$(defaults read -g AppleInterfaceStyle 2>/dev/null || echo "Light")
        if [ "$MODE" = "Dark" ]; then
          IS_DARK="true"
        else
          IS_DARK="false"
        fi
      ''
    else
      ''
        MODE=$(${pkgs.glib}/bin/gsettings get org.gnome.desktop.interface color-scheme 2>/dev/null || echo "")
        if echo "$MODE" | grep -q "prefer-light"; then
          IS_DARK="false"
        else
          IS_DARK="true"
        fi
      '';

  darkModeHook = pkgs.writeShellScript "dark-mode-hook" ''
    IS_DARK="''${1:-}"
    if [ -z "$IS_DARK" ]; then
      ${detectDarkMode}
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

    mkdir -p "$HOME/.config/helix/themes"
    echo "inherits = \"$HELIX_THEME\"" > "$HOME/.config/helix/themes/active.toml"
    ${pkgs.procps}/bin/pkill -USR1 hx 2>/dev/null || true

    mkdir -p "$HOME/.config/lazygit"
    cat > "$HOME/.config/lazygit/theme.yml" <<EOF
gui:
  theme:
    lightTheme: $LAZYGIT_LIGHT
EOF

    ${pkgs.fish}/bin/fish "$FISH_COLORS" 2>/dev/null || true

    mkdir -p "$HOME/.config/zellij"
    cp "$ZELLIJ_CONFIG" "$HOME/.config/zellij/config.kdl"
    chmod 644 "$HOME/.config/zellij/config.kdl"
  '';

  currentGen = "$HOME/.local/state/home-manager/gcroots/current-home";

  activateSpecialisation = pkgs.writeShellScript "activate-specialisation" ''
    IS_DARK="''${1:-}"
    if [ -z "$IS_DARK" ]; then
      ${detectDarkMode}
    fi

    GEN="${currentGen}"
    if [ "$IS_DARK" = "false" ] && [ -e "$GEN/specialisation/light/activate" ]; then
      "$GEN/specialisation/light/activate"
    elif [ -e "$GEN/activate" ]; then
      "$GEN/activate"
    else
      ${darkModeHook} "$IS_DARK"
    fi
  '';
in
{
  config.dotfiles.darkModeHook = darkModeHook;

  config.home.packages = [
    (pkgs.writeShellScriptBin "theme-switch" ''
      exec ${activateSpecialisation} "$@"
    '')
  ];

  config.stylix = {
    enable = true;
    autoEnable = true;
    polarity = lib.mkDefault "dark";
    base16Scheme = lib.mkDefault "${pkgs.base16-schemes}/share/themes/${cfg.darkTheme.system}.yaml";
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

  config.specialisation.light.configuration = {
    stylix = {
      polarity = lib.mkForce "light";
      base16Scheme = lib.mkForce "${pkgs.base16-schemes}/share/themes/${cfg.lightTheme.system}.yaml";
    };
  };

  config.programs.zellij = {
    enable = true;
    enableFishIntegration = false;
  };

  config.home.activation.seedThemeConfigs = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    ${detectDarkMode}
    ${darkModeHook} "$IS_DARK"
    mkdir -p "$HOME/.cache"
    if [ "$IS_DARK" = "true" ]; then
      echo "Dark" > "$HOME/.cache/dark-mode-state"
    else
      echo "Light" > "$HOME/.cache/dark-mode-state"
    fi
  '';

  config.launchd.agents.dark-mode-watcher = lib.mkIf isOsx {
    enable = true;
    config = {
      ProgramArguments = [
        "${pkgs.writeShellScript "dark-mode-watcher" ''
          CURRENT=$(defaults read -g AppleInterfaceStyle 2>/dev/null || echo "Light")
          CACHE="$HOME/.cache/dark-mode-state"
          mkdir -p "$HOME/.cache"
          PREVIOUS=$(cat "$CACHE" 2>/dev/null || echo "")
          if [ "$CURRENT" != "$PREVIOUS" ]; then
            echo "$CURRENT" > "$CACHE"
            if [ "$CURRENT" = "Dark" ]; then
              ${activateSpecialisation} true
            else
              ${activateSpecialisation} false
            fi
          fi
        ''}"
      ];
      WatchPaths = [ "${config.home.homeDirectory}/Library/Preferences/.GlobalPreferences.plist" ];
      RunAtLoad = true;
    };
  };
}
