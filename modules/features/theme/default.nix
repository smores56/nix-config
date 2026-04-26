{ pkgs, ... }:
let
  defaultScheme = "base16-rose-pine-moon";
  defaultLightScheme = "base16-rose-pine-dawn";
  defaultDarkEditor = "rose_pine_moon";
  defaultLightEditor = "rose_pine_dawn";

  stateDir = "~/.local/state/theme";

  baseColors = "base00 base01 base02 base03 base04 base05 base06 base07 base08 base09 base0A base0B base0C base0D base0E base0F";

  helixThemesDir = "${pkgs.helix-unwrapped.HELIX_DEFAULT_RUNTIME}/themes";

  themeSwitcher = pkgs.writeShellScriptBin "theme-switch" ''
    exec bash ${./theme-switch.sh} "${pkgs.tinty}/bin/tinty" "$1" \
      "${defaultScheme}" "${defaultLightScheme}" "${defaultDarkEditor}" "${defaultLightEditor}"
  '';

  tintyHook = pkgs.writeShellScript "tinty-hook" ''
    FULL_SCHEME=$(tinty current 2>/dev/null)
    [ -z "$FULL_SCHEME" ] && exit 0

    SYSTEM="''${FULL_SCHEME%%-*}"
    SCHEME="''${FULL_SCHEME#*-}"
    SCHEMES_DIR="$HOME/.local/share/tinted-theming/tinty/repos/schemes/$SYSTEM"
    SCHEME_FILE="$SCHEMES_DIR/$SCHEME.yaml"
    [ ! -f "$SCHEME_FILE" ] && exit 0

    get_color() {
      grep "  $1:" "$SCHEME_FILE" | sed 's/.*"#\([0-9a-fA-F]*\)".*/\1/'
    }

    for base in ${baseColors}; do
      val=$(get_color "$base")
      [ -z "$val" ] && exit 1
      declare "$base=$val"
    done

    mkdir -p "$HOME/.config/wezterm/colors"
    cat > "$HOME/.config/wezterm/colors/tinted.toml" << WEZTERM
    [colors]
    foreground = "#$base05"
    background = "#$base00"
    cursor_bg = "#$base05"
    cursor_border = "#$base05"
    cursor_fg = "#$base00"
    selection_bg = "#$base02"
    selection_fg = "#$base05"
    ansi = ["#$base00", "#$base08", "#$base0B", "#$base0A", "#$base0D", "#$base0E", "#$base0C", "#$base05"]
    brights = ["#$base03", "#$base08", "#$base0B", "#$base0A", "#$base0D", "#$base0E", "#$base0C", "#$base07"]

    [metadata]
    name = "tinted"
    WEZTERM

    mkdir -p "$HOME/.config/zellij/themes"
    cat > "$HOME/.config/zellij/themes/tinted.kdl" << ZELLIJ
    themes {
        tinted {
            fg "#$base05"
            bg "#$base00"
            black "#$base00"
            red "#$base08"
            green "#$base0B"
            yellow "#$base0A"
            blue "#$base0D"
            magenta "#$base0E"
            cyan "#$base0C"
            white "#$base05"
            orange "#$base09"
        }
    }
    ZELLIJ

    VARIANT=$(grep "^variant:" "$SCHEME_FILE" | sed 's/variant: *"\(.*\)"/\1/')
    DELTA_MODE=$([ "$VARIANT" = "light" ] && echo "light" || echo "dark")
    LIGHT_THEME=$([ "$VARIANT" = "light" ] && echo "true" || echo "false")

    mkdir -p "$HOME/.config/lazygit"
    cat > "$HOME/.config/lazygit/theme.yml" << LAZYGIT
    git:
      paging:
        colorArg: always
        pager: "delta --paging=never --$DELTA_MODE"
    gui:
      theme:
        lightTheme: $LIGHT_THEME
    LAZYGIT

    if command -v borders &> /dev/null; then
      pkill -f borders 2>/dev/null || true
      borders active_color="0xFF$base0A" inactive_color="0xFF$base04" width=6 hidpi=on &
      disown
    fi
  '';

  themePreview = pkgs.writeShellScript "theme-preview" ''
    FULL="$1"
    SYSTEM="''${FULL%%-*}"
    NAME="''${FULL#*-}"
    SCHEMES_DIR="$HOME/.local/share/tinted-theming/tinty/repos/schemes/$SYSTEM"
    SCHEME_FILE="$SCHEMES_DIR/$NAME.yaml"
    [ ! -f "$SCHEME_FILE" ] && echo "Scheme not found: $SCHEME_FILE" && exit 0

    label=$(grep "^name:" "$SCHEME_FILE" | sed 's/name: *"\(.*\)"/\1/')
    variant=$(grep "^variant:" "$SCHEME_FILE" | sed 's/variant: *"\(.*\)"/\1/')
    echo "$label ($variant)"
    echo ""

    label_for() {
      case $1 in
        base00) echo bg;; base01) echo bg+;; base02) echo sel;; base03) echo comment;;
        base04) echo fg-;; base05) echo fg;; base06) echo fg+;; base07) echo bg++;;
        base08) echo red;; base09) echo orange;; base0A) echo yellow;; base0B) echo green;;
        base0C) echo cyan;; base0D) echo blue;; base0E) echo purple;; base0F) echo brown;;
      esac
    }

    for base in ${baseColors}; do
      hex=$(grep "  $base:" "$SCHEME_FILE" | sed 's/.*"#\([0-9a-fA-F]*\)".*/\1/')
      [ -z "$hex" ] && continue
      r=$(printf "%d" "0x$(echo "$hex" | cut -c1-2)")
      g=$(printf "%d" "0x$(echo "$hex" | cut -c3-4)")
      b=$(printf "%d" "0x$(echo "$hex" | cut -c5-6)")
      printf "\033[48;2;%d;%d;%dm    \033[0m %-7s #%s\n" "$r" "$g" "$b" "$(label_for "$base")" "$hex"
    done
  '';

  helixPreview = pkgs.writeShellScript "helix-theme-preview" ''
    exec bash ${./helix-preview.sh} "${helixThemesDir}" "$1"
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

      if not test -f ${stateDir}/mode
          mkdir -p ${stateDir}
          echo dark > ${stateDir}/mode
          echo ${defaultScheme} > ${stateDir}/dark_shell
          echo ${defaultLightScheme} > ${stateDir}/light_shell
          echo ${defaultDarkEditor} > ${stateDir}/dark_editor
          echo ${defaultLightEditor} > ${stateDir}/light_editor
      end
    '';

    functions.set-theme = {
      description = "Pick color schemes [shell|editor|mode|clear-light]";
      body = ''
        set -l state ${stateDir}
        set -l mode (cat $state/mode 2>/dev/null; or echo dark)
        set -l do_shell 1
        set -l do_editor 1

        if test (count $argv) -gt 0
            switch $argv[1]
                case mode
                    theme-switch toggle
                    return
                case clear-light
                    set -l target (test (count $argv) -gt 1; and echo $argv[2]; or echo both)
                    switch $target
                        case shell
                            rm -f $state/light_shell
                        case editor
                            rm -f $state/light_editor
                        case '*'
                            rm -f $state/light_shell $state/light_editor
                    end
                    echo "Cleared light variant for $target"
                    return
                case shell
                    set do_editor 0
                case editor
                    set do_shell 0
                case '*'
                    echo "Usage: set-theme [shell|editor|mode|clear-light [shell|editor]]"
                    return 1
            end
        end

        if test $do_shell -eq 1
            if command -q tinty
                if not test -d ~/.local/share/tinted-theming/tinty/repos/schemes
                    tinty install > /dev/null 2>&1
                end
                set -l current (tinty current 2>/dev/null)
                set -l scheme (tinty list | fzf --header "Shell theme ($mode) — current: $current" --preview '${themePreview} {}')
                if test -n "$scheme"
                    tinty apply "$scheme"
                    mkdir -p $state
                    echo "$scheme" > $state/{$mode}_shell
                end
            else
                echo "tinty not found"
            end
        end

        if test $do_editor -eq 1
            set -l current_editor ""
            if test -f ~/.config/helix/themes/active.toml
                set current_editor (grep 'inherits' ~/.config/helix/themes/active.toml | sed 's/.*"\(.*\)".*/\1/')
            end
            set -l theme (command ls ${helixThemesDir}/*.toml | sed 's|.*/||;s|\.toml$||' | sort | fzf --header "Helix theme ($mode) — current: $current_editor" --preview '${helixPreview} {}')
            if test -n "$theme"
                mkdir -p ~/.config/helix/themes
                echo "inherits = \"$theme\"" > ~/.config/helix/themes/active.toml
                mkdir -p $state
                echo "$theme" > $state/{$mode}_editor
                echo "Helix theme set to $theme ($mode) — C-r in helix to reload"
            end
        end
      '';
    };
  };
}
