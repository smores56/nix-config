{
  config,
  pkgs,
  lib,
  ...
}:
let
  graphical = config.machine.graphical;
  desktop = graphical && pkgs.stdenv.hostPlatform.isLinux;
  colors = config.lib.stylix.colors;
  scheme = config.stylix.base16Scheme;
  schemeName =
    if builtins.isAttrs scheme then
      scheme.slug or scheme.name or "base16"
    else
      let
        file = baseNameOf (toString scheme);
      in
      lib.removeSuffix ".yml" (lib.removeSuffix ".yaml" file);

  # eza merges LS_COLORS over its built-in theme. Stylix's vivid theme maps
  # directories to base0F, which is near-invisible on the darker palettes, so
  # eza gets a small palette-derived set instead of the full vivid output.
  hexToRgb =
    hex:
    let
      n = lib.fromHexString hex;
      b = n - 256 * builtins.div n 256;
      g = builtins.div n 256 - 256 * builtins.div n 65536;
      r = builtins.div n 65536;
    in
    "${toString r};${toString g};${toString b}";
  fg = base: "38;2;${hexToRgb colors.${base}}";
  lsColors = lib.concatStringsSep ":" [
    "di=1;${fg "base0D"}"
    "ln=1;${fg "base0C"}"
    "mh=1;${fg "base0C"}"
    "ex=1;${fg "base0B"}"
    "fi=${fg "base05"}"
    "no=${fg "base05"}"
    "or=1;${fg "base08"}"
    "mi=${fg "base08"}"
    "pi=${fg "base0A"}"
    "so=${fg "base0A"}"
    "bd=1;${fg "base0A"}"
    "cd=1;${fg "base0A"}"
    "su=1;${fg "base08"}"
    "sg=1;${fg "base0E"}"
    "tw=1;${fg "base0E"}"
    "ow=1;${fg "base0E"}"
    "st=${fg "base0E"}"
    "*.tar=${fg "base08"}"
    "*.tgz=${fg "base08"}"
    "*.zip=${fg "base08"}"
    "*.gz=${fg "base08"}"
    "*.bz2=${fg "base08"}"
    "*.xz=${fg "base08"}"
    "*.zst=${fg "base08"}"
    "*.md=${fg "base0A"}"
    "*.nix=${fg "base0D"}"
    "*.rs=${fg "base0E"}"
    "*.py=${fg "base0E"}"
    "*.ts=${fg "base0D"}"
    "*.js=${fg "base0A"}"
    "*.json=${fg "base0A"}"
    "*.toml=${fg "base0A"}"
    "*.yaml=${fg "base0A"}"
    "*.yml=${fg "base0A"}"
  ];
in
{
  config = {
    xdg.configFile."revdiff/config".text = ''
      [Application Options]
      theme = stylix
    '';

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
      pointerCursor.enable = lib.mkIf (graphical && pkgs.stdenv.hostPlatform.isLinux) true;
      sessionVariables.LS_COLORS = lsColors;
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
        kitty.fonts.enable = false;
        kitty.opacity.enable = false;
        # Zellij 0.44 ignores the external theme file this target writes, so the
        # theme is defined inline in modules/features/zellij.nix instead.
        zellij.enable = false;
        # GNOME's target writes dconf settings; this is a niri session, and the
        # rest are unused apps that also write dconf for no benefit.
        gnome.enable = false;
        gnome-text-editor.enable = false;
        eog.enable = false;
        # GTK and Qt are desktop-only; their target code and packages are
        # meaningless on the server and macOS hosts.
        gtk.enable = desktop;
        qt.enable = desktop;
      };
    };
  };
}
