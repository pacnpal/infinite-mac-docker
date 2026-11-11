#!/bin/sh
# Downloads and imports system disks and CD-ROMs into /data, then builds the
# app against them. server.mjs runs this in the background on every start;
# steps whose inputs haven't changed since the last run are skipped. Lines
# starting with "==> " show up on the /_import status page, and "==> Build
# ready" tells server.mjs to switch to the new build.
#
# Settings (environment):
#   INFINITE_MAC_SYSTEMS         all (default), classic (System 1 to 7.5.5
#                                only, no system downloads), or comma-separated name
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
    if [ "$(read_state built-from)" = "$build_key" ] &&
        [ "$(read_state disks-imported)" = "$disks_key" ] &&
        [ "$(read_state cdroms-imported)" = "$cdroms_key" ]; then
        delete_downloads_if_asked
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
        build_app
    fi

    if [ "$(read_state built-from)" != "$build_key" ]; then
        build_app
    fi

    python3 "$SRC/docker/gc.py" "$REPO" "$WORK/build" "$WORK/build.old"
    delete_downloads_if_asked
    echo "==> Done"
}

delete_downloads_if_asked() {
    if [ "$KEEP_DOWNLOADS" = "false" ] && [ -d "$CACHE" ]; then
        echo "==> Deleting the download cache"
        rm -rf "$CACHE"
    fi
}

sync_source() {
    echo "==> Syncing source"
    mkdir -p "$REPO"
    # Generated outputs are excluded, so rsync neither copies nor deletes them.
    rsync -a --delete \
        --exclude /node_modules --exclude /Images --exclude /Library \
        --exclude /build --exclude /.wrangler --exclude /.venv \
        --exclude /XADMaster-build \
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
    # Upstream builds lsar/unar from its XADMaster fork with Xcode; Debian's
    # unar package is the same tool for Linux.
    mkdir -p "$REPO/XADMaster-build/Release"
    ln -sfn /usr/bin/lsar "$REPO/XADMaster-build/Release/lsar"
    ln -sfn /usr/bin/unar "$REPO/XADMaster-build/Release/unar"
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
        write_state cdroms-imported "$cdroms_key"
    else
        echo "==> Importing CD-ROMs (about 35 GB of downloads for the self-hosted ones)"
        # The importer skips entries it can't fetch or extract and carries on;
        # count those so they're visible on the status page.
        {
            rc=0
            uv run scripts/import-cd-roms.py --keep-media 2>&1 || rc=$?
            echo "$rc" > "$WORK/cdroms.rc"
        } | tee "$WORK/cdroms.log"
        [ "$(cat "$WORK/cdroms.rc")" = 0 ] || return 1
        skipped="$(grep -c "ERROR, will be skipped" "$WORK/cdroms.log" || true)"
        # Skipped entries are retried on the next start (cheap: everything
        # else comes from the download cache), up to 3 runs per set of inputs,
        # so a permanently broken entry doesn't cost a re-scan every restart.
        attempts_file="$WORK/cdroms-attempts"
        attempts=0
        if [ "$(sed -n 1p "$attempts_file" 2>/dev/null)" = "$cdroms_key" ]; then
            attempts="$(sed -n 2p "$attempts_file")"
        fi
        attempts=$((attempts + 1))
        printf '%s\n%s\n' "$cdroms_key" "$attempts" > "$attempts_file"
        if [ "$skipped" = 0 ] || [ "$attempts" -ge 3 ]; then
            write_state cdroms-imported "$cdroms_key"
            rm -f "$attempts_file"
        fi
        if [ "$skipped" = 0 ]; then
            echo "==> CD-ROMs imported"
        elif [ "$attempts" -ge 3 ]; then
            echo "==> CD-ROMs imported, $skipped skipped after 3 tries (see cdroms.log in /data/work)"
        else
            echo "==> CD-ROMs imported, $skipped skipped, retrying on next start (see cdroms.log in /data/work)"
        fi
    fi
}

build_app() {
    echo "==> Building the app"
    rm -rf "$REPO/build"
    npx vp build
    # The running wrangler serves $WORK/build until server.mjs switches, so the
    # previous build is only removed on the next swap.
    rm -rf "$WORK/build.old"
    if [ -d "$WORK/build" ]; then
        mv "$WORK/build" "$WORK/build.old"
    fi
    mv "$REPO/build" "$WORK/build"
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
