{ pkgs, ... }:
let
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

    base00=$(get_color base00)
    base01=$(get_color base01)
    base02=$(get_color base02)
    base03=$(get_color base03)
    base04=$(get_color base04)
    base05=$(get_color base05)
    base06=$(get_color base06)
    base07=$(get_color base07)
    base08=$(get_color base08)
    base09=$(get_color base09)
    base0A=$(get_color base0A)
    base0B=$(get_color base0B)
    base0C=$(get_color base0C)
    base0D=$(get_color base0D)
    base0E=$(get_color base0E)
    base0F=$(get_color base0F)

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

    for base in base00 base01 base02 base03 base04 base05 base06 base07 base08 base09 base0A base0B base0C base0D base0E base0F; do
      hex=$(grep "  $base:" "$SCHEME_FILE" | sed 's/.*"#\([0-9a-fA-F]*\)".*/\1/')
      r=$(printf "%d" "0x$(echo "$hex" | cut -c1-2)")
      g=$(printf "%d" "0x$(echo "$hex" | cut -c3-4)")
      b=$(printf "%d" "0x$(echo "$hex" | cut -c5-6)")
      printf "\033[48;2;%d;%d;%dm    \033[0m %s #%s\n" "$r" "$g" "$b" "$base" "$hex"
    done
  '';
in
{
  home.packages = [ pkgs.tinty ];

  home.file.".config/tinted-theming/tinty/config.toml".text = ''
    shell = "fish -c '{}'"
    default-scheme = "base16-rose-pine-moon"

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
                  tinty apply (tinty current 2>/dev/null; or echo base16-rose-pine-moon) > /dev/null 2>&1
              end
              set -l scheme (tinty current 2>/dev/null)
              if test -n "$scheme"
                  set -l shell_script ~/.local/share/tinted-theming/tinty/repos/tinted-shell/scripts/"$scheme".sh
                  test -f "$shell_script"; and bash "$shell_script"
                  set -l fzf_script ~/.local/share/tinted-theming/tinty/repos/tinted-fzf/fish/"$scheme".fish
                  test -f "$fzf_script"; and source "$fzf_script"
              end
          end
      end
    '';

    functions.set-theme = {
      description = "Pick and apply a base16 color scheme";
      body = ''
        if not command -q tinty
          echo "tinty not found"
          return 1
        end

        tinty install > /dev/null 2>&1
        set scheme (tinty list | fzf --preview '${themePreview} {}')
        or return 0
        tinty apply $scheme
      '';
    };
  };
}
