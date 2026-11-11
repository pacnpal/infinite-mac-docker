# Self-hosting Infinite Mac with Docker

This image runs Infinite Mac with System 1 through System 7.5.5 (including
System 7.5.3, `/1996/System%207.5.3`). It uses the same Cloudflare Worker code
as infinitemac.org, run locally with `wrangler`/`workerd`. Disk chunks are
served from inside the image, so you don't need a Cloudflare account or R2.

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

`/data` holds wrangler's local state: visit counters and the Durable Object
behind virtual AppleTalk zones. Your files on the emulated Saved HD disk live
in your browser, not on the server.

## Build it yourself

From the repo root:

```bash
docker build -f docker/Dockerfile -t infinite-mac .
```

The build runs `import-disks minimal`, `import-cd-roms placeholder` and
`import-library placeholder`, so:

- Only System 1 through 7.5.5 have disk images. Later systems are still listed
  but their disks are empty, so they won't boot. The full import needs native Mini vMac and Basilisk II to
  rebuild Desktop databases, which doesn't work in a headless build.
- The Infinite HD folders and the CD-ROM list are placeholders.

## Changes from upstream

`worker/disk.ts`: when no R2 bucket is bound, chunks under `/Disk/` are read
from the bundled static assets instead of returning a 500. Upstream behavior
with R2 is unchanged.

## Keeping up with upstream

Use **Sync fork** on GitHub. The workflow in `.github/workflows/docker.yml`
rebuilds and publishes `latest` on every push to `main`.
