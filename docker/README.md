# Self-hosting Infinite Mac with Docker

This image runs Infinite Mac with the same Cloudflare Worker code as
infinitemac.org, run locally with `wrangler`/`workerd`. You don't need a
Cloudflare account or R2.

System 1 through 7.5.5 are in the image and work as soon as it starts. On first
start it also downloads and imports everything else into `/data`:

- **Every other system disk:** Mac OS 7.6 through 9.2.2, Mac OS X, NeXT, BeOS
  and A/UX, about 10 GB of downloads from upstream's GitHub releases.
- **The CD-ROM and floppy catalog:** about 285 entries. Some stream from
  archive.org through the server; the rest (about 130) are downloaded into
  `/data`, about 34 GB.

The site keeps working with System 1 through 7.5.5 while that runs, then
switches over to the new build by itself, first once the systems are in and
again once the CD-ROMs are. Progress is at `/_import`.

Images are published for `linux/amd64` and `linux/arm64`:

```
ghcr.io/pacnpal/infinite-mac-docker:latest
```

## Run it

```bash
docker run -d --name infinite-mac \
  -p 3127:3127 \
  -v /path/to/appdata:/data \
  ghcr.io/pacnpal/infinite-mac-docker:latest
```

Or use [`compose.yaml`](compose.yaml): `docker compose -f docker/compose.yaml up -d`.

Then open `http://localhost:3127/`.

### HTTPS is required for other machines

Browsers only allow the features the emulator relies on (SharedArrayBuffer and
service workers) on HTTPS or `localhost`. Over plain HTTP from another machine,
such as `http://tower:3127`, the Mac still boots, but keyboard and mouse input
don't work and the Saved HD disk is missing. Put the container behind your
reverse proxy (SWAG, Nginx Proxy Manager, Caddy, Traefik, a Cloudflare Tunnel,
Tailscale Serve, and so on).

The proxy must pass these response headers through unchanged:

- `Cross-Origin-Opener-Policy: same-origin`
- `Cross-Origin-Embedder-Policy: require-corp`

### Traefik

The image already tells Traefik to forward to port 3127. Routing is opt-in, so
add these labels to the container (they're in `compose.yaml` and the Unraid
template too):

```
traefik.enable=true
traefik.http.routers.infinite-mac.rule=Host(`mac.example.com`)
traefik.http.routers.infinite-mac.entrypoints=websecure
traefik.http.routers.infinite-mac.tls=true
traefik.http.routers.infinite-mac.tls.certresolver=letsencrypt
```

Use your own hostname, HTTPS entrypoint name and cert resolver. Drop the
`certresolver` label if you use a wildcard or default certificate. The
container has to be on the same Docker network as Traefik; if it's on several
networks, add `traefik.docker.network=<that network>`.

Traefik passes the server's `Cross-Origin-*` headers through by default. Don't
attach a headers middleware that replaces them.

## Unraid

1. Copy [`unraid/infinite-mac.xml`](unraid/infinite-mac.xml) to
   `/boot/config/plugins/dockerMan/templates-user/my-infinite-mac.xml` on the
   server:

   ```bash
   wget -O /boot/config/plugins/dockerMan/templates-user/my-infinite-mac.xml \
     https://raw.githubusercontent.com/pacnpal/infinite-mac-docker/main/docker/unraid/infinite-mac.xml
   ```

2. Docker tab, **Add Container**, pick **infinite-mac** from the template list,
   then **Apply**.

The template maps `/data` to `/mnt/user/appdata/infinite-mac` and runs as
`99:100` (nobody:users), like other Unraid containers. It also has the Traefik
labels: change the host rule to your domain, and set **Network Type** to the
custom network your Traefik container uses. If you don't use Traefik, set
`traefik.enable` to `false`.

## Settings

| Variable | Default | Purpose |
| --- | --- | --- |
| `PORT` | `3127` | Port the server listens on inside the container |
| `PUID` | `99` | User ID to run as (ignored if you start the container with `--user`) |
| `PGID` | `100` | Group ID to run as |

On start, anything in `/data` not owned by `PUID:PGID` is chowned to it, so
changing these later is safe. If you use `--user` instead, the container can't
do that, so `/data` must already be writable by that user.

### What gets downloaded

| Variable | Default | Purpose |
| --- | --- | --- |
| `INFINITE_MAC_SYSTEMS` | `all` | `all`, `classic` (System 1 to 7.5.5 only, nothing downloaded), or comma-separated name filters such as `Mac OS 8,Mac OS 9`. System 1 to 7.5.5 are always included. |
| `INFINITE_MAC_CDROMS` | `all` | `all`, or `none` to skip the CD-ROM and floppy catalog |
| `INFINITE_MAC_KEEP_DOWNLOADS` | `true` | Keep the download cache, so a re-import after an image update doesn't download again. `false` deletes it after each import. |
| `INFINITE_MAC_IMPORT` | | `none` turns the import off entirely |

Changing these takes effect on the next start. Only the affected part is
redone.

## Storage, memory and time

Everything lives under `/data`:

- `home/.infinite-mac-cache`: the downloads (about 10 GB for systems, about
  34 GB more for CD-ROMs)
- `work/repo/Images/build`: imported disk chunks
- `work/repo/CD-ROMs/build/media`: self-hosted CD-ROM and floppy media
- `work/build`: the app build being served
- `state`: wrangler's local state (visit counters, virtual AppleTalk zones)

A complete import hasn't been measured yet, so treat these as rough: plan on
25 GB or more with `INFINITE_MAC_CDROMS=none`, and roughly 100 GB with
everything while the download cache is kept. The cache and the imported media
are separate copies, which is why `INFINITE_MAC_KEEP_DOWNLOADS=false` saves so
much. The tradeoff is downloading again when an image update needs a
re-import.

The import reads whole disk images into memory, so give the container several
GB of RAM while it runs. How long it takes depends mostly on your connection
and archive.org's speed; expect hours for the CD-ROMs.

If the container stops mid-import, the next start picks up from the download
cache. Your files on the emulated Saved HD disk live in your browser, not on
the server.

### Updates

After pulling a new image, the next start rebuilds the app (a few seconds) and
re-imports only what the update changed. Upstream's `CHANGELOG.md` is written
onto the system disks, so most upstream updates re-import the systems from the
download cache.

## Not included: the software library

The Infinite HD folders (apps and games) and the Macintosh Garden browser stay
placeholders. Upstream builds the library with macOS-only tools: `hdiutil`,
their macOS build of `unar`, resource forks read through `..namedfork/rsrc`,
and a Desktop DB rebuild in native Basilisk II. Porting that to Linux is
separate work.

## Build it yourself

From the repo root:

```bash
docker build -f docker/Dockerfile -t infinite-mac .
```

## How it works

- `docker/server.mjs` listens on `PORT`. It serves disk chunks and self-hosted
  CD-ROM media straight from `/data` (and the image), and proxies everything
  else, WebSockets included, to wrangler on an internal port.
- `docker/import.sh` does the downloading, importing and app build, and skips
  steps whose inputs haven't changed.
- `docker/entrypoint.sh` fixes `/data` ownership and drops to `PUID:PGID`.

Changes outside `docker/`:

- `scripts/import-disks.py`: a `systems` mode that imports every system disk
  without the macOS-only software library build, and accepts comma-separated
  filters.
- `worker/cd-rom.ts`: without an R2 bucket, self-hosted media is read from
  `LOCAL_MEDIA_ORIGIN` (the front server) instead of failing.

## Keeping up with upstream

Use **Sync fork** on GitHub. The workflow in `.github/workflows/docker.yml`
rebuilds and publishes `latest` on every push to `main`.
