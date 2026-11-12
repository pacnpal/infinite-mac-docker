#!/bin/sh
# Runs the server as PUID:PGID (Unraid convention: 99:100, nobody:users) so
# files written to the /data volume are owned by that user on the host. If the
# container was started with --user, that user is used as-is.
set -e
umask 022

mkdir -p "$HOME"

run_as=""
if [ "$(id -u)" = "0" ]; then
    PUID="${PUID:-99}"
    PGID="${PGID:-100}"
    # Fix anything left over from an earlier PUID/PGID (or created as root),
    # touching only entries that don't already match.
    find /data \( ! -user "$PUID" -o ! -group "$PGID" \) \
        -exec chown -h "$PUID:$PGID" {} +
    run_as="setpriv --reuid=$PUID --regid=$PGID --clear-groups"
fi

# shellcheck disable=SC2086 # run_as is intentionally word-split.
exec $run_as node /app/src/docker/server.mjs "$@"
