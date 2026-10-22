{
  config,
  pkgs,
  lib,
  ...
}:
let
  graphical = config.machine.graphical;
  colors = config.lib.stylix.colors;
  scheme = config.stylix.base16Scheme;
  # Common Stylix schemes share their slug with a Chroma style. A scheme
  # without a matching Chroma style needs a local override.
  schemeName =
    if builtins.isAttrs scheme then
      scheme.slug or scheme.name or "base16"
    else
      let
        file = baseNameOf (toString scheme);
      in
      lib.removeSuffix ".yml" (lib.removeSuffix ".yaml" file);
in
{
  config = {
    xdg.configFile."revdiff/themes/stylix".text = ''
      # name: stylix
      # description: generated from the Stylix base16 palette; do not edit
      # author: nix-config
      # bundled: false

      chroma-style = ${schemeName}
      color-accent = #${colors.base0D}
      color-border = #${colors.base02}
      color-normal = #${colors.base05}
      color-muted = #${colors.base03}
      color-selected-fg = #${colors.base00}
      color-selected-bg = #${colors.base0D}
      color-annotation = #${colors.base0A}
      color-cursor-fg = #${colors.base0C}
      color-add-fg = #${colors.base0C}
      color-add-bg = #${colors.base01}
      color-remove-fg = #${colors.base08}
      color-remove-bg = #${colors.base01}
      color-modify-fg = #${colors.base09}
      color-modify-bg = #${colors.base01}
      color-status-fg = #${colors.base00}
      color-status-bg = #${colors.base0D}
      color-search-fg = #${colors.base00}
      color-search-bg = #${colors.base09}
    '';

    home = {
      # stylix only sets home.pointerCursor on Linux.
      pointerCursor.enable = lib.mkIf (graphical && pkgs.stdenv.hostPlatform.isLinux) true;
    };

    stylix = {
      enable = true;
      autoEnable = true;
      polarity = "dark";
      base16Scheme = "${pkgs.base16-schemes}/share/themes/rose-pine-moon.yaml";

      fonts.monospace = {
        package = config.user.fontPackage;
        name = config.user.font;
      };

      cursor = lib.mkIf graphical {
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
  };
}
