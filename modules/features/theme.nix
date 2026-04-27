{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.dotfiles;

  darkModeHook = pkgs.writeShellScript "dark-mode-hook" ''
    sleep 0.2
    MODE=$(${pkgs.glib}/bin/gsettings get org.gnome.desktop.interface color-scheme 2>/dev/null || echo "")
    if echo "$MODE" | grep -q "prefer-light"; then
      HELIX_THEME="${cfg.lightTheme.helix}"
      LAZYGIT_LIGHT="true"
    else
      HELIX_THEME="${cfg.darkTheme.helix}"
      LAZYGIT_LIGHT="false"
    fi

    mkdir -p "$HOME/.config/helix/themes"
    echo "inherits = \"$HELIX_THEME\"" > "$HOME/.config/helix/themes/active.toml"

    mkdir -p "$HOME/.config/lazygit"
    cat > "$HOME/.config/lazygit/theme.yml" << EOF
    gui:
      theme:
        lightTheme: $LAZYGIT_LIGHT
    EOF
  '';
in
{
  options.programs.opencode.tui = lib.mkOption {
    type = lib.types.anything;
    default = { };
  };

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
    };
  };

  config.home.activation.seedHelixTheme = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    mkdir -p "$HOME/.config/helix/themes"
    if [ ! -f "$HOME/.config/helix/themes/active.toml" ]; then
      echo 'inherits = "${cfg.darkTheme.helix}"' > "$HOME/.config/helix/themes/active.toml"
    fi
  '';
}
