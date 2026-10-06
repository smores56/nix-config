{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.dotfiles;

  isOsx = cfg.displayManager == "osx";
  baseIsDark = cfg.polarity != "light";

  themeApply = import ../lib/theme-apply.nix { inherit pkgs lib; };

  baseGenFile = "$HOME/.cache/hm-base-generation";
  appliedStateFile = "$HOME/.cache/theme-applied";

  # Applies the theme files stylix does not manage directly (helix, lazygit) for
  # the given polarity. The OS appearance is deliberately NOT written here: the
  # native setting (macOS Appearance / Noctalia theme mode) is the source of
  # truth, so we only ever follow it.
  darkModeHook = pkgs.writeShellScript "dark-mode-hook" ''
      IS_DARK="''${1:-true}"

      if [ "$IS_DARK" = "false" ]; then
        helix_theme="${cfg.lightTheme.helix}"
        lazygit_light="true"
      else
        helix_theme="${cfg.darkTheme.helix}"
        lazygit_light="false"
      fi

      mkdir -p "$HOME/.config/helix/themes"
      echo "inherits = \"$helix_theme\"" > "$HOME/.config/helix/themes/active.toml"
      ${pkgs.procps}/bin/pkill -USR1 hx 2>/dev/null || true

      mkdir -p "$HOME/.config/lazygit"
      cat > "$HOME/.config/lazygit/theme.yml" <<EOF
    gui:
      theme:
        lightTheme: $lazygit_light
    EOF

      # Zellij's theme is switched by the stylix specialisation; it applies on the
      # next attach (`zellij kill-all-sessions` + re-attach for running sessions).
  '';

  # dark-mode-notify sets DARKMODE=1|0 before invoking its command.
  themeApplyDarwin = pkgs.writeShellScript "theme-apply-darwin" ''
    exec ${themeApply}/bin/theme-apply "$([ "''${DARKMODE:-0}" = 1 ] && echo dark || echo light)"
  '';
in
{
  config = {
    home = {
      # stylix only sets home.pointerCursor on Linux.
      pointerCursor.enable = lib.mkIf (cfg.graphical && pkgs.stdenv.hostPlatform.isLinux) true;

      activation = {
        saveBaseGeneration = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
          if [ -z "''${HM_SPECIALISATION_SWITCH:-}" ]; then
            mkdir -p "$HOME/.cache"
            # Record the generation being activated, not current-home — HM only
            # repoints that root at the very end of this script.
            echo "$newGenPath" > "${baseGenFile}"
            echo "$newGenPath" > "${appliedStateFile}"
          fi
        '';

        seedThemeConfigs = lib.hm.dag.entryAfter [ "saveBaseGeneration" ] ''
          IS_DARK="${if config.stylix.polarity == "dark" then "true" else "false"}"
          ${darkModeHook} "$IS_DARK"
        '';
      };
    };

    stylix = {
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

      cursor = lib.mkIf cfg.graphical {
        package = pkgs.bibata-cursors;
        name = "Bibata-Modern-Classic";
        size = 24;
      };

      targets = {
        firefox.fonts.enable = false;
        kitty.fonts.enable = false;
        kitty.opacity.enable = false;
        helix.enable = false;
        lazygit.enable = false;
        opencode.enable = false;
        gtk.enable = false;
        gnome.enable = lib.mkDefault false;
        gnome-text-editor.enable = false;
        eog.enable = false;
      };
    };

    specialisation =
      if baseIsDark then
        {
          light.configuration = {
            stylix = {
              polarity = lib.mkForce "light";
              base16Scheme = lib.mkForce "${pkgs.base16-schemes}/share/themes/${cfg.lightTheme.system}.yaml";
            };
            programs.zellij.settings.theme = lib.mkForce "stylix-light";
          };
        }
      else
        {
          dark.configuration = {
            stylix = {
              polarity = lib.mkForce "dark";
              base16Scheme = lib.mkForce "${pkgs.base16-schemes}/share/themes/${cfg.darkTheme.system}.yaml";
            };
            programs.zellij.settings.theme = lib.mkForce "stylix-dark";
          };
        };

    # macOS: follow the system appearance. dark-mode-notify subscribes to
    # AppleInterfaceThemeChangedNotification and runs the apply script on start
    # and on every appearance change — push, no polling.
    launchd.agents.dark-mode-notify = lib.mkIf isOsx {
      enable = true;
      config = {
        ProgramArguments = [
          "${pkgs.dark-mode-notify}/bin/dark-mode-notify"
          "${themeApplyDarwin}"
        ];
        KeepAlive = true;
        RunAtLoad = true;
      };
    };
  };
}
