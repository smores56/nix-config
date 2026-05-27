#!/bin/sh
set -e

echo "Deploying kandev proxy block on smoresnet..."

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
MANAGED_BEGIN="# BEGIN managed kandev proxy"
MANAGED_END="# END managed kandev proxy"
TMP="$HOME/Caddyfile.kandev.$$"
BACKUP="/etc/caddy/Caddyfile.bak.kandev"

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
$0 ~ /^[[:space:]]*kandev[.]sammohr[.]dev[[:space:]]*[{]/ {
    mode = "oldblock"
    depth = brace_delta($0)
    if (depth <= 0) mode = ""
    next
}
{
    print
}
'"'"' /etc/caddy/Caddyfile > "$TMP"

{
    printf "\n%s\n" "$MANAGED_BEGIN"
    cat "$HOME/kandev-Caddyfile"
    printf "%s\n" "$MANAGED_END"
} >> "$TMP"

$SUDO cp /etc/caddy/Caddyfile "$BACKUP"
$SUDO cp "$TMP" /etc/caddy/Caddyfile
rm -f "$TMP"

echo "Restarting Caddy..."
$SUDO /sbin/rc-service caddy restart 2>&1
echo "Done. Test: curl -sI https://kandev.sammohr.dev | head -5"'

REMOTE_SCRIPT_FILE="$(mktemp)"
printf '%s\n' "$remote_script" > "$REMOTE_SCRIPT_FILE"

scp Caddyfile "smores@smoresnet:~/kandev-Caddyfile"
scp "$REMOTE_SCRIPT_FILE" "smores@smoresnet:~/kandev-deploy.sh"
rm -f "$REMOTE_SCRIPT_FILE"
ssh -t smores@smoresnet "sh ~/kandev-deploy.sh; rm -f ~/kandev-deploy.sh"
