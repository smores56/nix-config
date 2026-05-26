#!/bin/sh
set -e

echo "Deploying OpenChamber proxy on smoresnet..."

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
$SUDO cp "$HOME/Caddyfile" /etc/caddy/Caddyfile
$SUDO rc-service caddy restart
echo "Done. Test: curl -sI https://opencode.sammohr.dev | head -5"'

scp Caddyfile smores@smoresnet:~
ssh smores@smoresnet "$remote_script"
