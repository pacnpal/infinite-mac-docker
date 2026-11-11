#!/bin/sh
# Downloads and imports system disks and CD-ROMs into /data, then builds the
# app against them. server.mjs runs this in the background on every start;
# steps whose inputs haven't changed since the last run are skipped. Lines
# starting with "==> " show up on the /_import status page, and "==> Build
# ready" tells server.mjs to switch to the new build.
#
# Settings (environment):
#   INFINITE_MAC_SYSTEMS         all (default), classic (System 1 to 7.5.5
#                                only, no downloads), or comma-separated name
#                                filters such as "Mac OS 8,Mac OS 9" (System 1
#                                to 7.5.5 always stay)
#   INFINITE_MAC_CDROMS          all (default) or none
#   INFINITE_MAC_KEEP_DOWNLOADS  true (default) keeps the download cache, so a
#                                re-import after an image update doesn't
#                                download again; false deletes it afterwards
set -eu

SRC="${APP_DIR:-/app}/src"
WORK="${DATA_DIR:-/data}/work"
REPO="$WORK/repo"
CACHE="$HOME/.infinite-mac-cache"
SYSTEMS="${INFINITE_MAC_SYSTEMS:-all}"
CDROMS="${INFINITE_MAC_CDROMS:-all}"
KEEP_DOWNLOADS="${INFINITE_MAC_KEEP_DOWNLOADS:-true}"

disks_key="$(cat "$SRC/.disks-hash") systems=$SYSTEMS"
cdroms_key="$(cat "$SRC/.cdroms-hash") cdroms=$CDROMS"
build_key="$(cat "$SRC/.source-hash") $disks_key $cdroms_key"

main() {
    mkdir -p "$WORK"
    if [ "$(read_state built-from)" = "$build_key" ]; then
        echo "==> Up to date"
        exit 0
    fi

    sync_source
    cd "$REPO"

    # The app build needs CD-ROM and library catalogs to exist.
    [ -f src/Data/CD-ROMs.json ] || uv run scripts/import-cd-roms.py placeholder
    [ -f src/Data/Library-index.json ] || uv run scripts/import-library.py placeholder

    if [ "$(read_state disks-imported)" != "$disks_key" ]; then
        import_disks
        write_state disks-imported "$disks_key"
        build_app
    fi

    if [ "$(read_state cdroms-imported)" != "$cdroms_key" ]; then
        import_cdroms
        write_state cdroms-imported "$cdroms_key"
        build_app
    fi

    if [ "$(read_state built-from)" != "$build_key" ]; then
        build_app
    fi

    if [ "$KEEP_DOWNLOADS" = "false" ] && [ -d "$CACHE" ]; then
        echo "==> Deleting the download cache"
        rm -rf "$CACHE"
    fi
    echo "==> Done"
}

sync_source() {
    echo "==> Syncing source"
    mkdir -p "$REPO"
    # Generated outputs are excluded, so rsync neither copies nor deletes them.
    rsync -a --delete \
        --exclude /node_modules --exclude /Images --exclude /Library \
        --exclude /build --exclude /.wrangler --exclude /.venv \
        --exclude /CD-ROMs/build --exclude /public/Covers \
        --exclude '/src/Data/*.dsk.json' --exclude /src/Data/CD-ROMs.json \
        --exclude '/src/Data/Library-*.json' \
        "$SRC/" "$REPO/"
    # Large read-only inputs stay in the image.
    ln -sfn "$SRC/node_modules" "$REPO/node_modules"
    ln -sfn "$SRC/Library" "$REPO/Library"
    mkdir -p "$REPO/Images/build"
    for f in "$SRC"/Images/*; do
        name="$(basename "$f")"
        [ "$name" = build ] || ln -sfn "$f" "$REPO/Images/$name"
    done
    find "$REPO/Images" -maxdepth 1 -type l ! -exec test -e {} \; -delete
}

import_disks() {
    rm -f "$WORK/disks-imported"
    case "$SYSTEMS" in
        classic)
            echo "==> Importing System 1 to 7.5.5"
            uv run scripts/import-disks.py minimal
            ;;
        all)
            echo "==> Downloading and importing all system disks (about 10 GB)"
            uv run scripts/import-disks.py systems
            ;;
        *)
            echo "==> Downloading and importing system disks matching \"$SYSTEMS\""
            DEBUG_SYSTEM_FILTER="$SYSTEMS" uv run scripts/import-disks.py systems
            ;;
    esac
    uv run scripts/import-library.py placeholder
}

import_cdroms() {
    rm -f "$WORK/cdroms-imported"
    if [ "$CDROMS" = none ]; then
        echo "==> Skipping CD-ROMs"
        uv run scripts/import-cd-roms.py placeholder
    else
        echo "==> Importing CD-ROMs (about 35 GB of downloads for the self-hosted ones)"
        uv run scripts/import-cd-roms.py
    fi
}

build_app() {
    echo "==> Building the app"
    rm -rf "$REPO/build"
    npx vp build
    rm -rf "$WORK/build.old"
    if [ -d "$WORK/build" ]; then
        mv "$WORK/build" "$WORK/build.old"
    fi
    mv "$REPO/build" "$WORK/build"
    rm -rf "$WORK/build.old"
    write_state built-from "$(cat "$SRC/.source-hash") $(read_state disks-imported) $(read_state cdroms-imported)"
    echo "==> Build ready"
}

read_state() {
    cat "$WORK/$1" 2>/dev/null || true
}

write_state() {
    echo "$2" > "$WORK/$1"
}

main
