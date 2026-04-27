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

  darkFishColors = pkgs.writeText "dark-fish-colors.fish" (fishColorsScript darkColors);
  lightFishColors = pkgs.writeText "light-fish-colors.fish" (fishColorsScript lightColors);

  darkModeHook = pkgs.writeShellScript "dark-mode-hook" ''
    sleep 0.2
    MODE=$(${pkgs.glib}/bin/gsettings get org.gnome.desktop.interface color-scheme 2>/dev/null || echo "")
    if echo "$MODE" | grep -q "prefer-light"; then
      HELIX_THEME="${cfg.lightTheme.helix}"
      LAZYGIT_LIGHT="true"
      FISH_COLORS="${lightFishColors}"
    else
      HELIX_THEME="${cfg.darkTheme.helix}"
      LAZYGIT_LIGHT="false"
      FISH_COLORS="${darkFishColors}"
    fi

    # Helix: update active theme and signal reload
    mkdir -p "$HOME/.config/helix/themes"
    echo "inherits = \"$HELIX_THEME\"" > "$HOME/.config/helix/themes/active.toml"
    ${pkgs.procps}/bin/pkill -USR1 hx 2>/dev/null || true

    # Lazygit: update theme for next launch
    mkdir -p "$HOME/.config/lazygit"
    cat > "$HOME/.config/lazygit/theme.yml" << EOF
    gui:
      theme:
        lightTheme: $LAZYGIT_LIGHT
    EOF

    # Fish: update universal color variables (affects all running sessions)
    ${pkgs.fish}/bin/fish "$FISH_COLORS" 2>/dev/null || true

    # Yazi: TODO — yazi doesn't support runtime theme reloading yet.
    # Stylix generates the theme at build time; runtime switching would
    # require writing ~/.config/yazi/theme.toml and restarting yazi.

    # Zellij: TODO — zellij doesn't support runtime theme reloading.
    # Stylix generates the theme at build time; runtime switching would
    # require writing a theme file and restarting zellij.
  '';
in
{
  config.dotfiles.darkModeHook = darkModeHook;

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
      # Fish colors are managed by the darkModeHook for runtime switching.
      # Disable Stylix's static fish target so it doesn't conflict.
      fish.enable = false;
    };
  };

  config.home.activation.seedHelixTheme = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    mkdir -p "$HOME/.config/helix/themes"
    if [ ! -f "$HOME/.config/helix/themes/active.toml" ]; then
      echo 'inherits = "${cfg.darkTheme.helix}"' > "$HOME/.config/helix/themes/active.toml"
    fi
  '';

  config.home.activation.seedFishColors = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    ${pkgs.fish}/bin/fish "${darkFishColors}" 2>/dev/null || true
  '';
}
