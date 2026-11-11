# syntax=docker/dockerfile:1
#
# Self-hosted Infinite Mac, served by the same Cloudflare Worker code as
# infinitemac.org, run locally with wrangler/workerd behind a small Node front
# server (docker/server.mjs).
#
# The image ships System 1 through 7.5.5 so it works right away. On first
# start it downloads and imports every other system disk and the CD-ROM
# catalog into /data, then switches over (see docker/import.sh).
#
# Build from the repo root:
#   docker build -f docker/Dockerfile -t infinite-mac .

ARG NODE_IMAGE=node:26-bookworm
ARG RUNTIME_IMAGE=node:26-bookworm-slim

FROM --platform=$BUILDPLATFORM ghcr.io/astral-sh/uv:0.13.7 AS uv-build
FROM ghcr.io/astral-sh/uv:0.13.7 AS uv-target

# The baked build is platform-independent (JS, WebAssembly, disk chunks), so
# make it once on the native platform.
FROM --platform=$BUILDPLATFORM ${NODE_IMAGE} AS baked
COPY --from=uv-build /uv /usr/local/bin/uv
ENV UV_LINK_MODE=copy
WORKDIR /src
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev
COPY . .
RUN npm run import-disks minimal \
    && npm run import-cd-roms placeholder \
    && npm run import-library placeholder \
    && npm run build

# The runtime keeps the source and toolchain so it can import into /data.
FROM ${RUNTIME_IMAGE}
RUN apt-get update \
    && apt-get install -y --no-install-recommends python3 rsync git unar ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=uv-target /uv /usr/local/bin/uv
ENV UV_PROJECT_ENVIRONMENT=/app/venv \
    UV_PYTHON_DOWNLOADS=never \
    UV_LINK_MODE=copy \
    UV_FROZEN=1 \
    UV_NO_SYNC=1 \
    PATH=/app/src/node_modules/.bin:$PATH

WORKDIR /app/src
COPY package.json package-lock.json ./
# vite writes its cache into node_modules/.vite; PUID varies at runtime.
RUN npm ci --no-audit --no-fund \
    && npm cache clean --force \
    && rm -rf /root/.npm \
    && mkdir -p node_modules/.vite \
    && chmod 1777 node_modules/.vite
COPY pyproject.toml uv.lock ./
RUN uv sync --no-dev --no-install-project --no-cache
COPY . .
# Fingerprints import.sh uses to decide what to redo after an image update.
# A changed .disks-hash or .cdroms-hash means re-importing that part (from the
# download cache); a changed .source-hash means rebuilding the app.
RUN hash_tree() { find "$@" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1; } \
    && hash_tree scripts Images Library CHANGELOG.md pyproject.toml uv.lock > .disks-hash \
    && hash_tree scripts CD-ROMs pyproject.toml uv.lock > .cdroms-hash \
    && hash_tree . -path ./node_modules -prune -o > .source-hash \
    && chmod +x docker/*.sh

COPY --from=baked /src/build /app/baked/build
COPY --from=baked /src/Images/build /app/baked/Images/build
# wrangler writes scratch files next to its config; PUID varies at runtime.
RUN mkdir -p /app/baked/build/infinite_mac/.wrangler \
    && chmod 1777 /app/baked/build/infinite_mac/.wrangler

WORKDIR /app
ENV PORT=3127 \
    PUID=99 \
    PGID=100 \
    HOME=/data/home \
    WRANGLER_SEND_METRICS=false \
    CI=1
EXPOSE 3127
# Tells Traefik which port to route to. Routing itself is opt-in: set
# traefik.enable=true and a Host rule on the container (see docker/README.md).
# Don't add Traefik header middlewares that replace the Cross-Origin-* headers
# the server sends; the emulator needs them.
LABEL traefik.http.services.infinite-mac.loadbalancer.server.port="3127"
# Imported disks, CD-ROMs, the download cache, and wrangler state.
VOLUME /data

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s \
    CMD node -e "fetch('http://127.0.0.1:'+process.env.PORT+'/').then(r=>process.exit(r.ok?0:1),()=>process.exit(1))"

ENTRYPOINT ["/app/src/docker/entrypoint.sh"]
