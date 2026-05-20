#!/bin/sh
set -e

echo "Deploying OpenChamber proxy on smoresnet..."

sudo cp ~/Caddyfile /etc/caddy/Caddyfile
sudo /sbin/rc-service caddy restart

echo "Done. Test: curl -I https://opencode.sammohr.dev"
