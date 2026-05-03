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

  darkFishColors = pkgs.writeText "dark-fish-colors.fish" (fishColorsScript darkColors);
  lightFishColors = pkgs.writeText "light-fish-colors.fish" (fishColorsScript lightColors);

  zellij = config.programs.zellij.package;

  isOsx = cfg.displayManager == "osx";
  isAutoSwitch = cfg.polarity == "time-of-day";
  baseIsDark = cfg.polarity != "light";
  cacheFile = "$HOME/.cache/dark-mode-state";

  detectDarkMode =
    if isOsx then
      ''
        MODE=$(/usr/bin/defaults read -g AppleInterfaceStyle 2>/dev/null || echo "Light")
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
          ZELLIJ_ACTION="set-light-theme"
        else
          HELIX_THEME="${cfg.darkTheme.helix}"
          LAZYGIT_LIGHT="false"
          FISH_COLORS="${darkFishColors}"
          ZELLIJ_ACTION="set-dark-theme"
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

        ${zellij}/bin/zellij list-sessions --short 2>/dev/null | while IFS= read -r session; do
          ${zellij}/bin/zellij --session "$session" action "$ZELLIJ_ACTION" 2>/dev/null || true
        done

        mkdir -p "$HOME/.cache"
        if [ "$IS_DARK" = "true" ]; then
          echo "Dark" > "${cacheFile}"
        else
          echo "Light" > "${cacheFile}"
        fi

        ${
          if isOsx then
            ''
              if [ "$IS_DARK" = "true" ]; then
                /usr/bin/defaults write -g AppleInterfaceStyle Dark
              else
                /usr/bin/defaults delete -g AppleInterfaceStyle 2>/dev/null || true
              fi
            ''
          else
            lib.optionalString (cfg.displayManager != "none") ''
              ${pkgs.glib}/bin/gsettings set org.gnome.desktop.interface color-scheme \
                "$([ "$IS_DARK" = "true" ] && echo "prefer-dark" || echo "prefer-light")" 2>/dev/null || true
            ''
        }
  '';

  baseGenFile = "$HOME/.cache/hm-base-generation";

  activateSpecialisation = pkgs.writeShellScript "activate-specialisation" ''
    IS_DARK="''${1:-}"
    if [ -z "$IS_DARK" ]; then
      ${detectDarkMode}
    fi

    BASE_GEN=$(cat "${baseGenFile}" 2>/dev/null)
    if [ -z "$BASE_GEN" ] || [ ! -d "$BASE_GEN" ]; then
      BASE_GEN=$(${pkgs.coreutils}/bin/readlink -f "$HOME/.local/state/home-manager/gcroots/current-home")
    fi

    export HM_SPECIALISATION_SWITCH=1
    if [ "$IS_DARK" = "false" ] && [ -e "$BASE_GEN/specialisation/light/activate" ]; then
      "$BASE_GEN/specialisation/light/activate"
    elif [ "$IS_DARK" = "true" ] && [ -e "$BASE_GEN/specialisation/dark/activate" ]; then
      "$BASE_GEN/specialisation/dark/activate"
    elif [ -e "$BASE_GEN/activate" ]; then
      "$BASE_GEN/activate"
    else
      ${darkModeHook} "$IS_DARK"
    fi
  '';
in
{
  config.dotfiles.darkModeHook = darkModeHook;

  config.home.packages = [
    (pkgs.writeShellScriptBin "theme-switch" ''
      case "''${1:-}" in
        dark)  ${activateSpecialisation} true  && echo "Switched to dark theme" ;;
        light) ${activateSpecialisation} false && echo "Switched to light theme" ;;
        "")    ${activateSpecialisation}       && echo "Theme synced to system setting" ;;
        *)     echo "Usage: theme-switch [dark|light]" >&2; exit 1 ;;
      esac
    '')
  ];

  config.stylix = {
    enable = true;
    autoEnable = true;
    polarity = lib.mkDefault (if baseIsDark then "dark" else "light");
    base16Scheme = lib.mkDefault "${pkgs.base16-schemes}/share/themes/${
      if baseIsDark then cfg.darkTheme.system else cfg.lightTheme.system
    }.yaml";
    image = ../../wallpapers/rocket-launch.png;

    fonts.monospace = {
      package = cfg.fontPackage;
      name = cfg.font;
    };

    cursor = lib.mkIf (cfg.displayManager != "none") {
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

  config.specialisation =
    if baseIsDark then
      {
        light.configuration.stylix = {
          polarity = lib.mkForce "light";
          base16Scheme = lib.mkForce "${pkgs.base16-schemes}/share/themes/${cfg.lightTheme.system}.yaml";
        };
      }
    else
      {
        dark.configuration.stylix = {
          polarity = lib.mkForce "dark";
          base16Scheme = lib.mkForce "${pkgs.base16-schemes}/share/themes/${cfg.darkTheme.system}.yaml";
        };
      };

  config.home.activation.saveBaseGeneration = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    if [ -z "''${HM_SPECIALISATION_SWITCH:-}" ]; then
      gen=$(${pkgs.coreutils}/bin/readlink -f "$HOME/.local/state/home-manager/gcroots/current-home" 2>/dev/null)
      if [ -n "$gen" ]; then
        mkdir -p "$HOME/.cache"
        echo "$gen" > "${baseGenFile}"
      fi
    fi
  '';

  config.home.activation.seedThemeConfigs = lib.hm.dag.entryAfter [ "saveBaseGeneration" ] ''
    ${lib.optionalString isOsx (
      if isAutoSwitch then
        "/usr/bin/defaults write -g AppleInterfaceStyleSwitchesAutomatically -bool true"
      else
        "/usr/bin/defaults write -g AppleInterfaceStyleSwitchesAutomatically -bool false"
    )}
    IS_DARK="${if config.stylix.polarity == "dark" then "true" else "false"}"
    ${darkModeHook} "$IS_DARK"
  '';

  config.launchd.agents.dark-mode-watcher = lib.mkIf (isOsx && isAutoSwitch) {
    enable = true;
    config = {
      ProgramArguments = [
        "${pkgs.writeShellScript "dark-mode-watcher" ''
          CURRENT=$(/usr/bin/defaults read -g AppleInterfaceStyle 2>/dev/null || echo "Light")
          CACHE="${cacheFile}"
          mkdir -p "$HOME/.cache"
          PREVIOUS=$(cat "$CACHE" 2>/dev/null || echo "")
          if [ "$CURRENT" != "$PREVIOUS" ]; then
            if [ "$CURRENT" = "Dark" ]; then
              ${activateSpecialisation} true && echo "$CURRENT" > "$CACHE"
            else
              ${activateSpecialisation} false && echo "$CURRENT" > "$CACHE"
            fi
          fi
        ''}"
      ];
      WatchPaths = [ "${config.home.homeDirectory}/Library/Preferences/.GlobalPreferences.plist" ];
      ThrottleInterval = 5;
      RunAtLoad = true;
    };
  };
}
