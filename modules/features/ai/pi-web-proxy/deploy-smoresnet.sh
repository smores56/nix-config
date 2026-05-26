#!/bin/sh
set -e

echo "Deploying pi-web proxy block on smoresnet..."

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
if grep -q "pi.sammohr.dev" /etc/caddy/Caddyfile; then
    echo "pi.sammohr.dev block already present, skipping append."
else
    $SUDO sh -c "cat \"$HOME/pi-web-Caddyfile\" >> /etc/caddy/Caddyfile"
fi
$SUDO rc-service caddy reload
echo "Done. Test: curl -sI https://pi.sammohr.dev | head -5"'

scp Caddyfile "smores@smoresnet:~/pi-web-Caddyfile"
ssh smores@smoresnet "$remote_script"
