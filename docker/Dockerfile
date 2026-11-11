# syntax=docker/dockerfile:1
#
# Self-hosted Infinite Mac: System 1 through System 7.5.5, served by the same
# Cloudflare Worker code as infinitemac.org, run locally with wrangler/workerd.
# Disk chunks are bundled with the static assets instead of living in R2.
#
# Build from the repo root:
#   docker build -f docker/Dockerfile -t infinite-mac .

ARG NODE_IMAGE=node:26-bookworm
ARG RUNTIME_IMAGE=node:26-bookworm-slim

FROM --platform=$BUILDPLATFORM ghcr.io/astral-sh/uv:0.13.7 AS uv

# The build output is platform-independent (JS, WebAssembly, disk chunks), so
# build once on the native platform and only vary the runtime stage per arch.
FROM --platform=$BUILDPLATFORM ${NODE_IMAGE} AS build
COPY --from=uv /uv /usr/local/bin/uv
ENV UV_LINK_MODE=copy
WORKDIR /src

COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen

COPY . .
# "minimal" imports System 1 through 7.5.5. The full set needs native Mini vMac
# and Basilisk II to rebuild Desktop databases, which doesn't work headless.
RUN npm run import-disks minimal \
    && npm run import-cd-roms placeholder \
    && npm run import-library placeholder
RUN npm run build \
    && mkdir -p build/client/Images \
    && cp -r Images/build build/client/Images/build \
    && node -p "require('./package-lock.json').packages['node_modules/wrangler'].version" \
        > build/wrangler-version

FROM ${RUNTIME_IMAGE}
COPY --from=build /src/build/wrangler-version /tmp/wrangler-version
RUN npm install -g --no-audit --no-fund "wrangler@$(cat /tmp/wrangler-version)" \
    && npm cache clean --force \
    && rm -rf /root/.npm /tmp/wrangler-version

WORKDIR /app
COPY --from=build /src/build ./build
COPY docker/entrypoint.sh /usr/local/bin/infinite-mac
# wrangler writes scratch files in the working directory and next to its
# config; PUID varies at runtime, so leave them world-writable.
RUN mkdir -p .wrangler build/infinite_mac/.wrangler \
    && chmod 1777 .wrangler build/infinite_mac/.wrangler

ENV PORT=3127 \
    PUID=99 \
    PGID=100 \
    HOME=/data/home \
    WRANGLER_SEND_METRICS=false \
    CI=1
EXPOSE 3127
# KV counters and Durable Object (virtual AppleTalk zone) state.
VOLUME /data

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s \
    CMD node -e "fetch('http://127.0.0.1:'+process.env.PORT+'/').then(r=>process.exit(r.ok?0:1),()=>process.exit(1))"

ENTRYPOINT ["/usr/local/bin/infinite-mac"]
