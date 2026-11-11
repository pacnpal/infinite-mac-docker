#!/bin/sh
# Runs wrangler as PUID:PGID (Unraid convention: 99:100, nobody:users) so files
# written to the /data volume are owned by that user on the host. If the
# container was started with --user, that user is used as-is.
set -e

if [ "$(id -u)" = "0" ]; then
    PUID="${PUID:-99}"
    PGID="${PGID:-100}"
    mkdir -p /data
    chown "$PUID:$PGID" /data
    exec setpriv --reuid="$PUID" --regid="$PGID" --clear-groups "$0" "$@"
fi

mkdir -p "$HOME"
exec wrangler dev \
    --config /app/build/infinite_mac/wrangler.json \
    --ip 0.0.0.0 \
    --port "$PORT" \
    --persist-to /data/state \
    --show-interactive-dev-session=false \
    "$@"
