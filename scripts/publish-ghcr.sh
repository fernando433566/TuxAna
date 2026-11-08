#!/usr/bin/env bash
# Publica la imagen multi-arquitectura (linux/amd64 + linux/arm64) en GitHub Container Registry
# con las etiquetas "latest" y la versión de server/Cargo.toml, en un PC x86_64 con Docker y buildx.
#
# Antes, una vez:
#   echo "$TOKEN" | docker login ghcr.io -u <usuario> --password-stdin      (token con permiso write:packages)
#
#   scripts/publish-ghcr.sh [ghcr.io/<usuario>/tuxana]
set -euo pipefail
cd "$(dirname "$0")/.."
IMAGE="${1:-ghcr.io/fernando433566/tuxana}"
VERSION="$(grep -m1 '^version' server/Cargo.toml | cut -d'"' -f2)"

# Las imágenes multi-arquitectura necesitan un builder "docker-container"
docker buildx inspect tuxana-builder >/dev/null 2>&1 || docker buildx create --name tuxana-builder --driver docker-container >/dev/null

docker buildx build --builder tuxana-builder \
  --platform linux/amd64,linux/arm64 \
  --build-arg VERSION="$VERSION" \
  -t "$IMAGE:$VERSION" -t "$IMAGE:latest" \
  --push .

docker buildx imagetools inspect "$IMAGE:$VERSION"
