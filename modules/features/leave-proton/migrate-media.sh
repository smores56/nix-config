#!/usr/bin/env bash
# Move the media libraries into /var/lib/data (T7, sdlc #295).
# Run as root AFTER switching to the new configuration. Services may be down
# during/after the move; restart them (and the user's calibre unit) afterwards.
set -euo pipefail

[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }

data=/var/lib/data
agent=/var/lib/agent
media=/var/lib/media

install -d -o smores -g users -m 0775 "$agent" "$data/music" "$data/books" "$agent/books-ingest"
install -d -o immich -g immich -m 0700 "$data/photos"

move() {
  src=$1 dst=$2
  if [ -d "$src" ]; then
    echo "== $src -> $dst"
    rsync -aHAX --remove-source-files "$src"/ "$dst"/
    find "$src" -mindepth 1 -type d -empty -delete
    rmdir "$src" 2>/dev/null || true
  fi
}

move "$media/Music" "$data/music"
move "$media/Calibre" "$data/books"
move "$media/Calibre-Ingest" "$agent/books-ingest"
move "$media/Photos" "$data/photos"

chown -R smores:users "$data/music" "$data/books" "$agent/books-ingest"
chown -R immich:immich "$data/photos"

echo
echo "Done. Restart the consumers:"
echo "  sudo systemctl restart immich-server"
echo "  systemctl --user restart calibre-server   # as smores"
echo "  curl -fsS http://127.0.0.1:2283/api/server/ping"
echo "  df -h $data"
