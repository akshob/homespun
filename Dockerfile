# syntax=docker/dockerfile:1
# SPDX-License-Identifier: AGPL-3.0-only
#
# Homespun Server in a container, for a NAS or any computer with Docker.
# See "Run on a NAS with Docker" in README.md, and deploy/compose.yaml.
#
#   docker build -t homespun-server .
#   docker buildx build --platform linux/amd64,linux/arm64 -t ghcr.io/akshob/homespun-server:latest --push .

ARG SWIFT_VERSION=6.3
ARG UBUNTU_VERSION=24.04

FROM swift:${SWIFT_VERSION}-noble AS build
RUN export DEBIAN_FRONTEND=noninteractive \
    && apt-get update \
    && apt-get install -y --no-install-recommends libvips-dev libsqlite3-dev \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
# Dependencies first, so a change to the server's code doesn't fetch them again.
COPY Package.swift Package.resolved ./
RUN swift package resolve --force-resolved-versions
COPY Sources ./Sources
# SwiftPM wants every target's folder, test targets included, even to build one product.
COPY Tests ./Tests
RUN swift build -c release --product homespun-server --static-swift-stdlib \
    && install -D -m 0755 "$(swift build -c release --show-bin-path)/homespun-server" /out/homespun-server \
    && strip /out/homespun-server

FROM ubuntu:${UBUNTU_VERSION}
# libvips (photos; the libde265 plugin decodes HEIC), ffmpeg with x265 (videos), SQLite (the
# catalog), avahi-utils (Bonjour through the host's avahi-daemon), curl (the health check).
RUN export DEBIAN_FRONTEND=noninteractive \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        libvips42t64 libheif-plugin-libde265 libsqlite3-0 ffmpeg avahi-utils ca-certificates curl \
    && rm -rf /var/lib/apt/lists/* \
    && userdel --remove ubuntu \
    && groupadd --gid 1000 homespun \
    && useradd --uid 1000 --gid homespun --home-dir /data --no-create-home --shell /usr/sbin/nologin homespun \
    && mkdir -p /data /originals \
    && chown homespun:homespun /data /originals
COPY --from=build /out/homespun-server /usr/local/bin/homespun-server

LABEL org.opencontainers.image.title="Homespun Server" \
      org.opencontainers.image.description="Keeps full-quality photo and video originals; the Homespun iPhone app keeps compact copies in Apple Photos." \
      org.opencontainers.image.url="https://homespun.photos" \
      org.opencontainers.image.source="https://github.com/akshob/homespun" \
      org.opencontainers.image.licenses="AGPL-3.0-only"

# Catalog and compact copies in /data, originals in /originals (a folder per phone). Listens on
# every address with HTTPS; the server's encryption key lives in /data/tls. Back it up.
ENV HOMESPUN_DATA=/data \
    HOMESPUN_ORIGINALS=/originals \
    HOMESPUN_HOST=0.0.0.0 \
    HOMESPUN_PORT=8787 \
    HOMESPUN_HARDWARE_KIND=container \
    HOMESPUN_COMMAND="docker exec homespun homespun-server"
VOLUME ["/data", "/originals"]
EXPOSE 8787
# Run as your own NAS user instead with `user: "UID:GID"` (compose) or `--user UID:GID`.
USER homespun:homespun
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD curl -fsSk -o /dev/null "https://127.0.0.1:${HOMESPUN_PORT}/api/v1/health" || exit 1
ENTRYPOINT ["homespun-server"]
CMD ["serve"]
