#!/bin/sh
set -e

echo "Deploying keep.sammohr.dev Caddy block to smoresnet..."

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

remote_script='#!/bin/sh
set -e
SUDO=""
if command -v doas >/dev/null 2>&1; then
    SUDO=doas
elif command -v sudo >/dev/null 2>&1; then
    SUDO=sudo
else
    echo "Neither sudo nor doas found"
    exit 1
fi
MANAGED_BEGIN="# BEGIN managed keep.sammohr.dev"
MANAGED_END="# END managed keep.sammohr.dev"
CADDYFILE="/etc/caddy/Caddyfile"
TMP="/tmp/Caddyfile.keep.$$"
BACKUP="$CADDYFILE.bak.keep"

$SUDO awk -v begin="$MANAGED_BEGIN" -v end="$MANAGED_END" '\''
function brace_delta(s, i, c, d) {
    d = 0
    for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c == "{") d++
        else if (c == "}") d--
    }
    return d
}
$0 == begin {
    mode = "managed"
    next
}
mode == "managed" {
    if ($0 == end) mode = ""
    next
}
mode == "oldblock" {
    depth += brace_delta($0)
    if (depth <= 0) mode = ""
    next
}
$0 ~ /^[[:space:]]*keep[.]sammohr[.]dev[[:space:]]*[{]/ {
    mode = "oldblock"
    depth = brace_delta($0)
    if (depth <= 0) mode = ""
    next
}
{
    print
}
'\'' "$CADDYFILE" > "$TMP"

{
    printf "\n%s\n" "$MANAGED_BEGIN"
    cat "$HOME/keep-Caddyfile"
    printf "%s\n" "$MANAGED_END"
} >> "$TMP"

chmod 644 "$TMP"
$SUDO cp "$CADDYFILE" "$BACKUP"
$SUDO cp "$TMP" "$CADDYFILE"
rm -f "$TMP"

echo "Restarting Caddy..."
$SUDO /sbin/rc-service caddy restart 2>&1
echo "Done. Test: curl -sI https://keep.sammohr.dev | head -5"'

REMOTE_SCRIPT_FILE="$(mktemp)"
printf '%s\n' "$remote_script" > "$REMOTE_SCRIPT_FILE"

scp "$SCRIPT_DIR/Caddyfile" "smores@smoresnet:~/keep-Caddyfile"
scp "$REMOTE_SCRIPT_FILE" "smores@smoresnet:~/keep-deploy.sh"
rm -f "$REMOTE_SCRIPT_FILE"
ssh -t smores@smoresnet "sh ~/keep-deploy.sh; rm -f ~/keep-deploy.sh"
