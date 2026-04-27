#!/usr/bin/env bash
BASE_COLORS="$1"

FULL_SCHEME=$(tinty current 2>/dev/null)
[ -z "$FULL_SCHEME" ] && exit 0

SYSTEM="${FULL_SCHEME%%-*}"
SCHEME="${FULL_SCHEME#*-}"
SCHEMES_DIR="$HOME/.local/share/tinted-theming/tinty/repos/schemes/$SYSTEM"
SCHEME_FILE="$SCHEMES_DIR/$SCHEME.yaml"
[ ! -f "$SCHEME_FILE" ] && exit 0

get_color() {
  grep "  $1:" "$SCHEME_FILE" | sed 's/.*"#\([0-9a-fA-F]*\)".*/\1/'
}

for base in $BASE_COLORS; do
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
visual_bell = "#$base01"

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
    selectedLineBgColor:
      - underline
    selectedRangeBgColor:
      - underline
LAZYGIT

if command -v borders &> /dev/null; then
  pkill -f borders 2>/dev/null || true
  borders active_color="0xFF$base0A" inactive_color="0xFF$base04" width=6 hidpi=on &
  disown
fi
