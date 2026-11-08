#!/usr/bin/env bash
# One-time base16 preview: a picker and a live maki session in one kitty OS window.
# Run from the nix-config checkout, pick a scheme, then delete this script.
set -euo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work="${XDG_CACHE_HOME:-$HOME/.cache}/theme-preview"
schemes=$(nix eval --raw --inputs-from "$repo" nixpkgs#base16-schemes.outPath)/share/themes
[ -d "$schemes" ] || {
  printf 'theme-preview: no base16 schemes at %s\n' "$schemes" >&2
  exit 1
}

command -v kitty >/dev/null || {
  printf 'theme-preview: kitty is not on PATH\n' >&2
  exit 1
}
command -v maki >/dev/null || {
  printf 'theme-preview: maki is not on PATH\n' >&2
  exit 1
}

if fzf=$(command -v fzf); then
  :
elif fzf_out=$(nix build --no-link --print-out-paths --inputs-from "$repo" nixpkgs#fzf 2>/dev/null); then
  fzf=$fzf_out/bin/fzf
else
  printf 'theme-preview: cannot obtain fzf\n' >&2
  exit 1
fi

rm -rf -- "$work"
mkdir -p -- "$work/conf"

# The tinted-kitty base16 template, byte-compatible with the include Stylix
# writes into kitty.conf. Trailing YAML comments fall into $3+, so $2 is the color.
convert() {
  awk '
    /^palette:/ { palette = 1; next }
    palette && /^[^ ]/ { palette = 0 }
    palette && /^  base[0-9A-Fa-f][0-9A-Fa-f]:/ {
      key = $1
      sub(/:$/, "", key)
      value = $2
      gsub(/"/, "", value)
      colors[key] = value
      seen++
    }
    END {
      if (seen != 16) exit 2
      printf "background %s\nforeground %s\nselection_background %s\nselection_foreground %s\n", colors["base00"], colors["base05"], colors["base03"], colors["base05"]
      printf "cursor %s\ncursor_text_color %s\nurl_color %s\n", colors["base05"], colors["base00"], colors["base04"]
      printf "active_border_color %s\ninactive_border_color %s\n", colors["base03"], colors["base01"]
      printf "wayland_titlebar_color %s\nmacos_titlebar_color %s\n", colors["base00"], colors["base00"]
      printf "active_tab_background %s\nactive_tab_foreground %s\ninactive_tab_background %s\ninactive_tab_foreground %s\ntab_bar_background %s\n", colors["base00"], colors["base05"], colors["base01"], colors["base04"], colors["base01"]
      split("base00 base08 base0B base0A base0D base0E base0C base05 base02 base08 base0B base0A base0D base0E base0C base07", normal, " ")
      for (i = 1; i <= 16; i++) printf "color%d %s\n", i - 1, colors[normal[i]]
      split("base09 base0F base01 base02 base04 base06", extended, " ")
      for (i = 1; i <= 6; i++) printf "color%d %s\n", 15 + i, colors[extended[i]]
    }
  ' "$1"
}

count=0
for yaml in "$schemes"/*.yaml; do
  name=$(basename -- "$yaml" .yaml)
  if ! convert "$yaml" >"$work/conf/$name.conf"; then
    printf 'theme-preview: skipping malformed scheme %s\n' "$yaml" >&2
    rm -f -- "$work/conf/$name.conf"
    continue
  fi
  count=$((count + 1))
done
[ "$count" -gt 0 ] || {
  printf 'theme-preview: no schemes converted\n' >&2
  exit 1
}

cat >"$work/apply" <<'APPLY'
#!/usr/bin/env bash
set -euo pipefail
exec "${KITTEN:-kitten}" @ set-colors -a -- "$THEME_PREVIEW_WORK/conf/$1.conf"
APPLY

cat >"$work/picker" <<'PICKER'
#!/usr/bin/env bash
set -euo pipefail
work=${THEME_PREVIEW_WORK:?}
kitten=${KITTEN:-kitten}
chosen=$work/chosen

names=$(find "$work/conf" -maxdepth 1 -name '*.conf' -printf '%f\n' | sed 's/\.conf$//' | sort)

if selected=$(printf '%s\n' "$names" |
  "$FZF" --ansi --no-info --reverse --height=100% --color=16 \
    --prompt='base16> ' \
    --header='Enter: keep this theme   Esc: restore the Stylix palette' \
    --bind "focus:execute-silent($work/apply {})"); then
  printf '%s\n' "$selected" >"$chosen"
  printf 'Selected base16 scheme: %s\n' "$selected"
  printf 'The palette stays applied while maki runs. Remember the name for the follow-up.\n'
  read -r -n 1 -s -p 'Press any key to close this pane...' || true
  printf '\n'
else
  "$kitten" @ set-colors --reset || true
  printf 'Restored the Stylix palette.\n'
  read -r -n 1 -s -p 'Press any key to close this pane...' || true
  printf '\n'
fi
PICKER
chmod +x "$work/apply" "$work/picker"

cat >"$work/session.conf" <<EOF
layout splits
launch --var role=picker --title base16-preview $work/picker
launch --location=vsplit --title maki maki
focus_matching_window var:role=picker
EOF

export THEME_PREVIEW_WORK=$work
export FZF=$fzf
KITTEN=$(command -v kitten)
export KITTEN

printf 'Converted %d base16 schemes.\n' "$count"
printf 'Starting kitty: picker on the left, maki (system theme) on the right.\n'
exec kitty -o allow_remote_control=yes --session "$work/session.conf"
