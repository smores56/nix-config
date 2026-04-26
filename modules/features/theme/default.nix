{ pkgs, ... }:
let
  defaultScheme = "base16-rose-pine-moon";
  defaultLightScheme = "base16-rose-pine-dawn";
  defaultDarkEditor = "rose_pine_moon";
  defaultLightEditor = "rose_pine_dawn";

  python = "${pkgs.python3}/bin/python3";
  stateDir = "~/.local/state/theme";

  baseColors = "base00 base01 base02 base03 base04 base05 base06 base07 base08 base09 base0A base0B base0C base0D base0E base0F";

  helixThemesDir = "${pkgs.helix-unwrapped.HELIX_DEFAULT_RUNTIME}/themes";

  themeSwitcher = pkgs.writeShellScriptBin "theme-switch" ''
    export TINTY="${pkgs.tinty}/bin/tinty"
    export DEFAULT_DARK_SHELL="${defaultScheme}"
    export DEFAULT_LIGHT_SHELL="${defaultLightScheme}"
    export DEFAULT_DARK_EDITOR="${defaultDarkEditor}"
    export DEFAULT_LIGHT_EDITOR="${defaultLightEditor}"
    exec ${python} ${./theme-switch.py} "$@"
  '';

  themePreview = pkgs.writeShellScript "theme-preview" ''
    exec ${python} ${./theme-preview.py} "$@"
  '';

  helixPreview = pkgs.writeShellScript "helix-theme-preview" ''
    exec ${python} ${./helix-preview.py} "${helixThemesDir}" "$@"
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
    default-scheme = "${defaultScheme}"

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

  programs.fish = {
    interactiveShellInit = ''
      if command -q tinty
          function __tinty_init --on-event fish_prompt
              functions --erase __tinty_init
              if not test -d ~/.local/share/tinted-theming/tinty/repos/schemes
                  tinty install > /dev/null 2>&1
              end
              theme-switch (cat ${stateDir}/mode 2>/dev/null; or echo dark)
          end
      end

      theme-switch init
    '';

    functions.set-theme = {
      description = "Pick color schemes [shell|editor|mode|clear-light]";
      body = ''
        set -l mode (theme-switch current)

        if test (count $argv) -gt 0
            switch $argv[1]
                case mode
                    theme-switch toggle
                    return
                case clear-light
                    theme-switch clear-light $argv[2..]
                    return
                case shell
                    __set_shell_theme $mode
                    return
                case editor
                    __set_editor_theme $mode
                    return
                case '*'
                    theme-switch --help
                    return 1
            end
        end

        __set_shell_theme $mode
        __set_editor_theme $mode
      '';
    };

    functions.__set_shell_theme = {
      description = "Pick a shell color scheme for the given mode";
      body = ''
        set -l mode $argv[1]
        if not command -q tinty
            echo "tinty not found"
            return 1
        end

        if not test -d ~/.local/share/tinted-theming/tinty/repos/schemes
            tinty install > /dev/null 2>&1
        end
        set -l current (tinty current 2>/dev/null)
        set -l scheme (tinty list | fzf --header "Shell theme ($mode) — current: $current" --preview '${themePreview} {}')
        if test -n "$scheme"
            tinty apply "$scheme"
            theme-switch save shell "$scheme"
        end
      '';
    };

    functions.__set_editor_theme = {
      description = "Pick a helix theme for the given mode";
      body = ''
        set -l mode $argv[1]
        set -l current_editor ""
        if test -f ~/.config/helix/themes/active.toml
            set current_editor (grep 'inherits' ~/.config/helix/themes/active.toml | sed 's/.*"\(.*\)".*/\1/')
        end
        set -l theme (command ls ${helixThemesDir}/*.toml | sed 's|.*/||;s|\.toml$||' | sort | fzf --header "Helix theme ($mode) — current: $current_editor" --preview '${helixPreview} {}')
        if test -n "$theme"
            mkdir -p ~/.config/helix/themes
            echo "inherits = \"$theme\"" > ~/.config/helix/themes/active.toml
            theme-switch save editor "$theme"
            echo "Helix theme set to $theme ($mode) — C-r in helix to reload"
        end
      '';
    };
  };
}
