#!/bin/sh
set -e

echo "Deploying omp-acp proxy block on smoresnet..."

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
MANAGED_BEGIN="# BEGIN managed omp-acp proxy"
MANAGED_END="# END managed omp-acp proxy"
TMP="$HOME/Caddyfile.omp-acp.$$"
BACKUP="/etc/caddy/Caddyfile.bak.omp-acp"

if [ -r /etc/conf.d/caddy ]; then
    . /etc/conf.d/caddy
fi

if [ -z "${OMP_ACP_BASIC_AUTH_HASH:-}" ]; then
    echo "OMP_ACP_BASIC_AUTH_HASH is not set for Caddy."
    echo "On smoresnet, run: caddy hash-password"
    echo "Then add the resulting hash to /etc/conf.d/caddy as:"
    echo "  export OMP_ACP_BASIC_AUTH_HASH='\''<hash>'\''"
    exit 1
fi

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
$0 ~ /^[[:space:]]*omp[.]sammohr[.]dev[[:space:]]*[{]/ {
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
    cat "$HOME/omp-acp-Caddyfile"
    printf "%s\n" "$MANAGED_END"
} >> "$TMP"

$SUDO cp /etc/caddy/Caddyfile "$BACKUP"
$SUDO cp "$TMP" /etc/caddy/Caddyfile
rm -f "$TMP"

if ! $SUDO rc-service caddy reload; then
    echo "Caddy reload failed; restoring previous Caddyfile."
    $SUDO cp "$BACKUP" /etc/caddy/Caddyfile
    $SUDO rc-service caddy reload || true
    echo "Make sure OMP_ACP_BASIC_AUTH_HASH is set in Caddy'\''s service environment."
    exit 1
fi
echo "Done. Test: curl -sI https://omp.sammohr.dev | head -5"'

scp Caddyfile "smores@smoresnet:~/omp-acp-Caddyfile"
ssh -t smores@smoresnet "$remote_script"
