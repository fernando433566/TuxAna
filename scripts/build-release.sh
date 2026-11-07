#!/usr/bin/env bash
# Compila todo para publicar una versión, en un PC x86_64 con Docker y buildx:
#   dist/bin/windows/   ana-engine.exe, rmproxy.dll        (se ejecutan dentro de Wine)
#   dist/bin/amd64/     tuxana                              (servidor Wyoming para Linux x86_64)
#   dist/bin/arm64/     tuxana                              (servidor Wyoming para Linux ARM64)
#   dist/images/        tuxana-<versión>-amd64.tar, tuxana-<versión>-arm64.tar   (imágenes Docker)
#
# Para la imagen arm64 hace falta la emulación de ARM una vez por arranque del PC:
#   docker run --privileged --rm tonistiigi/binfmt --install arm64
# Las imágenes no contienen ficheros de Microsoft, así que se pueden publicar.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="$(grep -m1 '^version' server/Cargo.toml | cut -d'"' -f2)"
mkdir -p dist/bin/windows dist/bin/amd64 dist/bin/arm64 dist/images

for arch in amd64 arm64; do
  echo "==> imagen $arch"
  docker buildx build --platform "linux/$arch" --build-arg VERSION="$VERSION" -t "tuxana:$VERSION-$arch" \
    -o "type=docker,dest=dist/images/tuxana-$VERSION-$arch.tar" .

  echo "==> binarios $arch"
  # la etapa "binaries" del Dockerfile contiene solo los programas compilados
  docker buildx build --platform "linux/$arch" --target binaries -o "type=local,dest=dist/.out-$arch" .
  cp "dist/.out-$arch/tuxana" "dist/bin/$arch/"
  cp "dist/.out-$arch/windows/"* dist/bin/windows/
  rm -rf "dist/.out-$arch"
done

(cd dist && find bin images -type f -exec sha256sum {} + | sort -k2 > SHA256SUMS)
echo "listo: dist/ (versión $VERSION)"
cat dist/SHA256SUMS
