"""Deletes imported disk chunks and CD-ROM media that nothing references.

Imports keep existing chunks and media (they're content-addressed, and a
running server may still be using them), so stale ones are cleaned up here
once a new build is in place. A file is kept if the current import outputs or
any app build passed on the command line still reference it.

Usage: gc.py REPO_DIR [BUILD_DIR ...]
"""

import glob
import json
import os
import re
import sys

CHUNK_RE = re.compile(rb"\b([0-9a-f]{32})\b")
MEDIA_RE = re.compile(rb"media/([0-9a-f]{64})\.media")


def main() -> int:
    repo_dir, build_dirs = sys.argv[1], sys.argv[2:]
    chunks: set[str] = set()
    media: set[str] = set()

    for manifest_path in glob.glob(os.path.join(repo_dir, "src", "Data", "*.dsk.json")):
        with open(manifest_path) as f:
            chunks.update(c for c in json.load(f).get("chunks", []) if c)
    cd_roms_path = os.path.join(repo_dir, "src", "Data", "CD-ROMs.json")
    if os.path.exists(cd_roms_path):
        with open(cd_roms_path, "rb") as f:
            media.update(m.decode() for m in MEDIA_RE.findall(f.read()))

    # Builds embed the manifests in their JS.
    for build_dir in build_dirs:
        for js_path in glob.glob(
            os.path.join(build_dir, "client", "**", "*.js"), recursive=True
        ):
            with open(js_path, "rb") as f:
                data = f.read()
            chunks.update(c.decode() for c in CHUNK_RE.findall(data))
            media.update(m.decode() for m in MEDIA_RE.findall(data))

    if not chunks:
        print("gc: no manifests found, skipping")
        return 0

    removed_chunks, freed = remove_unreferenced(
        os.path.join(repo_dir, "Images", "build"), ".chunk", chunks
    )
    removed_media, freed_media = remove_unreferenced(
        os.path.join(repo_dir, "CD-ROMs", "build", "media"), ".media", media
    )
    print(
        "gc: removed %d chunks and %d media files (%.1f MB)"
        % (removed_chunks, removed_media, (freed + freed_media) / 1e6)
    )
    return 0


def remove_unreferenced(
    directory: str, extension: str, keep: set[str]
) -> tuple[int, int]:
    removed = freed = 0
    if not os.path.isdir(directory):
        return removed, freed
    for name in os.listdir(directory):
        stem, ext = os.path.splitext(name)
        if ext != extension or stem in keep:
            continue
        path = os.path.join(directory, name)
        freed += os.path.getsize(path)
        os.remove(path)
        removed += 1
    return removed, freed


if __name__ == "__main__":
    sys.exit(main())
