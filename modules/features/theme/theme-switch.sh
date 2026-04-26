#!/usr/bin/env bash
TINTY="$1"
TARGET="$2"
STATE_DIR="$HOME/.local/state/theme"
DEFAULT_DARK_SHELL="$3"
DEFAULT_LIGHT_SHELL="$4"
DEFAULT_DARK_EDITOR="$5"
DEFAULT_LIGHT_EDITOR="$6"

current_mode() {
  cat "$STATE_DIR/mode" 2>/dev/null || echo "dark"
}

resolve_mode() {
  case "$1" in
    dark|light) echo "$1" ;;
    toggle) [ "$(current_mode)" = "dark" ] && echo "light" || echo "dark" ;;
    *)
      if command -v gsettings &>/dev/null; then
        CS=$(gsettings get org.gnome.desktop.interface color-scheme 2>/dev/null)
        [ "$CS" = "'prefer-light'" ] && echo "light" || echo "dark"
      else
        current_mode
      fi
      ;;
  esac
}

read_pref() {
  cat "$STATE_DIR/$1" 2>/dev/null
}

MODE=$(resolve_mode "$TARGET")
mkdir -p "$STATE_DIR"
echo "$MODE" > "$STATE_DIR/mode"

SHELL_THEME=$(read_pref "${MODE}_shell")
[ -z "$SHELL_THEME" ] && SHELL_THEME=$(read_pref "dark_shell")
[ -z "$SHELL_THEME" ] && SHELL_THEME="$DEFAULT_DARK_SHELL"
"$TINTY" apply "$SHELL_THEME" 2>/dev/null

EDITOR_THEME=$(read_pref "${MODE}_editor")
[ -z "$EDITOR_THEME" ] && EDITOR_THEME=$(read_pref "dark_editor")
[ -z "$EDITOR_THEME" ] && EDITOR_THEME="$DEFAULT_DARK_EDITOR"
mkdir -p "$HOME/.config/helix/themes"
echo "inherits = \"$EDITOR_THEME\"" > "$HOME/.config/helix/themes/active.toml"
