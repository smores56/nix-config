#!/usr/bin/env bash
THEMES_DIR="$1"
THEME="$2"
THEME_FILE="$THEMES_DIR/$THEME.toml"
[ ! -f "$THEME_FILE" ] && echo "Theme not found: $THEME" && exit 0

INHERITS=$(grep '^inherits' "$THEME_FILE" | head -1 | sed 's/inherits *= *"\([^"]*\)"/\1/')

extract_palette() {
  awk '/^\[palette\]/{f=1; next} /^\[/{f=0} f && /"#[0-9a-fA-F]/' "$1" | \
    sed 's/^[[:space:]]*\([a-zA-Z0-9_-]*\)[[:space:]]*=.*"#\([0-9a-fA-F]*\)".*/\1 \2/'
}

PALETTE=""
if [ -n "$INHERITS" ] && [ -f "$THEMES_DIR/$INHERITS.toml" ]; then
  PALETTE=$(extract_palette "$THEMES_DIR/$INHERITS.toml")
fi
CHILD=$(extract_palette "$THEME_FILE")
[ -n "$CHILD" ] && PALETTE=$(printf "%s\n%s" "$PALETTE" "$CHILD")
PALETTE=$(echo "$PALETTE" | awk 'NF {vals[$1]=$2} END {for (k in vals) print k, vals[k]}')

get_bg_ref() {
  grep '"ui.background"' "$1" 2>/dev/null | head -1 | \
    sed -n 's/.*bg *= *"\([^"]*\)".*/\1/p'
}

BG_REF=$(get_bg_ref "$THEME_FILE")
[ -z "$BG_REF" ] && [ -n "$INHERITS" ] && BG_REF=$(get_bg_ref "$THEMES_DIR/$INHERITS.toml")

resolve_hex() {
  local ref="$1"
  if echo "$ref" | grep -q '^#'; then
    echo "${ref#\#}"
  else
    echo "$PALETTE" | awk -v name="$ref" '$1 == name {print $2}'
  fi
}

echo "$THEME"
[ -n "$INHERITS" ] && echo "  inherits $INHERITS"

if [ -z "$BG_REF" ]; then
  printf "  \033[7m  transparent  \033[0m\n"
else
  BG_HEX=$(resolve_hex "$BG_REF")
  if [ -n "$BG_HEX" ] && [ ${#BG_HEX} -eq 6 ]; then
    r=$(printf "%d" "0x${BG_HEX:0:2}")
    g=$(printf "%d" "0x${BG_HEX:2:2}")
    b=$(printf "%d" "0x${BG_HEX:4:2}")
    printf "  \033[48;2;%d;%d;%dm      \033[0m bg #%s\n" "$r" "$g" "$b" "$BG_HEX"
  fi
fi
echo ""

if [ -z "$PALETTE" ]; then
  echo "  (uses terminal colors)"
  exit 0
fi

echo "$PALETTE" | sort | while read -r name hex; do
  [ -z "$hex" ] && continue
  [ ${#hex} -ne 6 ] && continue
  r=$(printf "%d" "0x${hex:0:2}")
  g=$(printf "%d" "0x${hex:2:2}")
  b=$(printf "%d" "0x${hex:4:2}")
  printf "\033[48;2;%d;%d;%dm    \033[0m %-20s #%s\n" "$r" "$g" "$b" "$name" "$hex"
done
