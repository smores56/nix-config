{ pkgs, ... }:
let
  defaultDarkScheme = "base16-rose-pine-moon";
  defaultLightScheme = "base16-rose-pine-dawn";
  defaultDarkEditor = "rose_pine_moon";
  defaultLightEditor = "rose_pine_dawn";

  python = "${pkgs.python3}/bin/python3";

  baseColors = "base00 base01 base02 base03 base04 base05 base06 base07 base08 base09 base0A base0B base0C base0D base0E base0F";

  helixThemesDir = "${pkgs.helix-unwrapped.HELIX_DEFAULT_RUNTIME}/themes";

  themePreview = pkgs.writeShellScript "theme-preview" ''
    exec ${python} ${./theme-preview.py} "$@"
  '';

  helixPreview = pkgs.writeShellScript "helix-theme-preview" ''
    exec ${python} ${./helix-preview.py} "${helixThemesDir}" "$@"
  '';

  themeSwitcher = pkgs.writeShellScriptBin "theme-switch" ''
    export TINTY="${pkgs.tinty}/bin/tinty"
    export THEME_PREVIEW="${themePreview}"
    export HELIX_PREVIEW="${helixPreview}"
    export HELIX_THEMES_DIR="${helixThemesDir}"
    export DEFAULT_DARK_SHELL="${defaultDarkScheme}"
    export DEFAULT_LIGHT_SHELL="${defaultLightScheme}"
    export DEFAULT_DARK_EDITOR="${defaultDarkEditor}"
    export DEFAULT_LIGHT_EDITOR="${defaultLightEditor}"
    exec ${python} ${./theme-switch.py} "$@"
  '';

  tintyHook = pkgs.writeShellScript "tinty-hook" ''
    exec bash ${./tinty-hook.sh} "${baseColors}"
  '';
in
{
  home.packages = [
    pkgs.tinty
    themeSwitcher
  ];

  home.file.".config/tinted-theming/tinty/config.toml".text = ''
    shell = "fish -c '{}'"
    default-scheme = "${defaultDarkScheme}"

    [[items]]
    path = "https://github.com/tinted-theming/tinted-shell"
    name = "tinted-shell"
    themes-dir = "scripts"
    supported-systems = ["base16", "base24"]
    hook = "${tintyHook}"

    [[items]]
    path = "https://github.com/tinted-theming/tinted-fzf"
    name = "tinted-fzf"
    themes-dir = "fish"
    supported-systems = ["base16", "base24"]
  '';

  programs.fish.interactiveShellInit = ''
    if command -q tinty
        function __tinty_init --on-event fish_prompt
            functions --erase __tinty_init
            if not test -d ~/.local/share/tinted-theming/tinty/repos/schemes
                tinty install > /dev/null 2>&1
            end
            theme-switch (cat ~/.local/state/theme/mode 2>/dev/null; or echo dark)
        end
    end

    theme-switch init
  '';

  programs.fish.shellAbbrs.ts = "theme-switch";
}
