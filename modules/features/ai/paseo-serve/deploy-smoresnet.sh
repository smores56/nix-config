#!/bin/sh
set -e

echo "Deploying paseo.sammohr.dev Caddy block + web app to smoresnet..."

SERVEDIR="$(cd "$(dirname "$0")" && pwd)"
WEB_DIST="${WEB_DIST:-/home/smores/code/paseo/packages/app/dist}"

if [ ! -d "$WEB_DIST" ]; then
    echo "Web app dist not found at $WEB_DIST"
    echo "Set WEB_DIST or build the Paseo web app first:"
    echo "  cd ~/code/paseo/packages/app && npm run build:web"
    exit 1
fi

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
MANAGED_BEGIN="# BEGIN managed paseo.sammohr.dev"
MANAGED_END="# END managed paseo.sammohr.dev"
CADDYFILE="/etc/caddy/Caddyfile"
TMP="/tmp/Caddyfile.paseo.$$"
BACKUP="$CADDYFILE.bak.paseo"

$SUDO awk -v begin="$MANAGED_BEGIN" -v end="$MANAGED_END" '"'"'
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
$0 ~ /^[[:space:]]*paseo[.]sammohr[.]dev[[:space:]]*[{]/ {
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
    cat "$HOME/paseo-Caddyfile"
    printf "%s\n" "$MANAGED_END"
} >> "$TMP"

$SUDO cp "$CADDYFILE" "$BACKUP"
$SUDO cp "$TMP" "$CADDYFILE"
rm -f "$TMP"

echo "Restarting Caddy..."
$SUDO /sbin/rc-service caddy restart 2>&1
echo "Done. Test: curl -sI https://paseo.sammohr.dev | head -5"'

echo "Copying web app build to smoresnet..."
REMOTE_SCRIPT_FILE="$(mktemp)"
printf '%s\n' "$remote_script" > "$REMOTE_SCRIPT_FILE"

ssh smoresnet "rm -rf ~/paseo-web"
scp -r "$WEB_DIST" "smores@smoresnet:~/paseo-web"
scp "$SERVEDIR/Caddyfile" "smores@smoresnet:~/paseo-Caddyfile"
scp "$REMOTE_SCRIPT_FILE" "smores@smoresnet:~/paseo-deploy.sh"
rm -f "$REMOTE_SCRIPT_FILE"
ssh -t smores@smoresnet "sh ~/paseo-deploy.sh; rm -f ~/paseo-deploy.sh"
