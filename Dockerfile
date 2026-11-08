# syntax=docker/dockerfile:1
#
# TuxAna: Microsoft Ana (Cortana's Spanish voice) as a Wyoming TTS server for Home Assistant.
#
#   linux/amd64  Wine x86_64 + Microsoft Speech Platform 11 + the x86_64 OneCore engine.
#   linux/arm64  Wine compiled for ARM64 + the ARM64 sapi_onecore.dll and OneCore engine: nothing is emulated.
#
# Everything that is compiled is cross-compiled on the build machine's own CPU (--platform=$BUILDPLATFORM),
# so the arm64 image can be built quickly on a PC. Wine itself only runs when the container starts:
# the first start creates the Wine prefix in /data (a volume), later starts reuse it.
#
# The image contains NO Microsoft files, so it can be published:
#   - the Windows files (from your own Windows, see windows-files/) are mounted read-only at /opt/ana/voice-files;
#   - on amd64 the Speech Platform 11 runtime is downloaded from Microsoft on the first start (checksum verified).

ARG DEBIAN=bookworm
ARG VERSION=1.1.0

# Same releases the project was developed and verified with.
ARG WINE_URL=https://github.com/Kron4ek/Wine-Builds/releases/download/11.17/wine-11.17-amd64-wow64.tar.xz
ARG WINE_SHA256=3211db09086bc6fbd769c0286f27790b32d6fc6fb0bc610dad6b59796f07d462
ARG WINE_SOURCE_URL=https://dl.winehq.org/wine/source/11.x/wine-11.17.tar.xz
ARG WINE_SOURCE_SHA256=8e752e29bba2901ad9f915139345c6ee67184b099d425704d915971ca5c055fc
ARG LLVM_MINGW=20261020
ARG LLVM_MINGW_SHA256_X86_64=55064b60b991a1e1e8090b8c2f84e82b22cfe5903d12c159d65064cf5e8ae335
ARG LLVM_MINGW_SHA256_AARCH64=ca16bb0f4f485876496fa46ad8d353c525eba57d0cf9e9e49ec1738fe4810151
ARG SPEECH_PLATFORM_URL=https://download.microsoft.com/download/A/6/4/A64012D6-D56F-4E58-85E3-531E56ABC0E6/x64_SpeechPlatformRuntime/SpeechPlatformRuntime.msi
ARG SPEECH_PLATFORM_SHA256=9c0a1d096e80f2ae77d5fc00b5d1a43b665c28ec6196911de3dce6d74c115137

# ---------------------------------------------------------------------------------------------
# 1. llvm-mingw: the compiler for Windows ARM64 programs
# ---------------------------------------------------------------------------------------------
FROM --platform=$BUILDPLATFORM debian:${DEBIAN}-slim AS llvm-mingw
ARG BUILDARCH LLVM_MINGW LLVM_MINGW_SHA256_X86_64 LLVM_MINGW_SHA256_AARCH64
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates xz-utils && rm -rf /var/lib/apt/lists/*
RUN case "$BUILDARCH" in amd64) A=x86_64; S=$LLVM_MINGW_SHA256_X86_64;; arm64) A=aarch64; S=$LLVM_MINGW_SHA256_AARCH64;; esac \
    && curl -fsSL --retry 5 --retry-all-errors -o /t.tar.xz "https://github.com/mstorsjo/llvm-mingw/releases/download/${LLVM_MINGW}/llvm-mingw-${LLVM_MINGW}-ucrt-ubuntu-22.04-$A.tar.xz" \
    && echo "$S  /t.tar.xz" | sha256sum -c - && mkdir /opt/llvm-mingw && tar -xJf /t.tar.xz -C /opt/llvm-mingw --strip-components=1 && rm /t.tar.xz

# ---------------------------------------------------------------------------------------------
# 2. Rust: the Wyoming server (Linux) and the programs that run inside Wine (Windows, same CPU as the image)
# ---------------------------------------------------------------------------------------------
FROM --platform=$BUILDPLATFORM rust:1.83-${DEBIAN} AS rust
ARG TARGETARCH BUILDARCH
# A cross C linker is only needed when the target CPU differs from ours.
RUN apt-get update && apt-get install -y --no-install-recommends gcc-mingw-w64-x86-64 \
    && if [ "$TARGETARCH" != "$BUILDARCH" ]; then case "$TARGETARCH" in \
         arm64) apt-get install -y --no-install-recommends gcc-aarch64-linux-gnu libc6-dev-arm64-cross ;; \
         amd64) apt-get install -y --no-install-recommends gcc-x86-64-linux-gnu libc6-dev-amd64-cross ;; \
       esac; fi \
    && rm -rf /var/lib/apt/lists/* \
    && rustup target add x86_64-pc-windows-gnu aarch64-pc-windows-gnullvm x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu
COPY --from=llvm-mingw /opt/llvm-mingw /opt/llvm-mingw
# llvm-mingw goes last: its x86_64-w64-mingw32-gcc must not replace the real one
ENV PATH=/usr/local/cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt/llvm-mingw/bin \
    CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER=aarch64-linux-gnu-gcc \
    CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER=x86_64-linux-gnu-gcc \
    CARGO_TARGET_AARCH64_PC_WINDOWS_GNULLVM_LINKER=aarch64-w64-mingw32-clang
WORKDIR /src
COPY windows-side windows-side
RUN mkdir -p /out/windows && cd windows-side && case "$TARGETARCH" in \
      amd64) cargo build --release --target x86_64-pc-windows-gnu \
             && cp target/x86_64-pc-windows-gnu/release/ana-engine.exe target/x86_64-pc-windows-gnu/release/rmproxy.dll /out/windows/ ;; \
      arm64) cargo build --release --target aarch64-pc-windows-gnullvm -p ana-engine \
             && cp target/aarch64-pc-windows-gnullvm/release/ana-engine.exe /out/windows/ ;; \
      *) echo "unsupported $TARGETARCH"; exit 1 ;; esac
COPY server server
RUN case "$TARGETARCH" in amd64) T=x86_64-unknown-linux-gnu;; arm64) T=aarch64-unknown-linux-gnu;; esac \
    && cd server && cargo build --release --target $T && cp target/$T/release/tuxana /out/

# Only the compiled programs, for `docker buildx build --target binaries -o type=local,dest=...` (scripts/build-release.sh)
FROM scratch AS binaries
COPY --from=rust /out/ /

# ---------------------------------------------------------------------------------------------
# 3. Wine for ARM64, headless, cross-compiled (only used by the arm64 image)
# ---------------------------------------------------------------------------------------------
FROM --platform=$BUILDPLATFORM debian:${DEBIAN} AS wine-arm64
ARG BUILDARCH WINE_SOURCE_URL WINE_SOURCE_SHA256
RUN if [ "$BUILDARCH" != arm64 ]; then dpkg --add-architecture arm64; fi && apt-get update && apt-get install -y --no-install-recommends \
      build-essential flex bison gettext curl ca-certificates xz-utils pkg-config libc6-dev:arm64 \
    && if [ "$BUILDARCH" != arm64 ]; then apt-get install -y --no-install-recommends gcc-aarch64-linux-gnu g++-aarch64-linux-gnu; fi
COPY --from=llvm-mingw /opt/llvm-mingw /opt/llvm-mingw
ENV PATH=/opt/llvm-mingw/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
RUN curl -fsSL --retry 5 --retry-all-errors -o /w.tar.xz "$WINE_SOURCE_URL" && echo "$WINE_SOURCE_SHA256  /w.tar.xz" | sha256sum -c - \
    && mkdir /wine && tar -xJf /w.tar.xz -C /wine --strip-components=1 && rm /w.tar.xz
# Wine's build tools run on the build machine
RUN mkdir /tools && cd /tools && CC=gcc /wine/configure --enable-win64 --disable-tests --without-x --without-freetype --without-mingw \
    && make -j"$(nproc)" tools/all tools/sfnt2fon/all tools/widl/all tools/winebuild/all tools/winedump/all tools/winegcc/all tools/wmc/all tools/wrc/all \
    && mkdir -p /tools/nls && cp /wine/nls/*.nls /tools/nls/
RUN mkdir /arm && cd /arm && /wine/configure --host=aarch64-linux-gnu --with-wine-tools=/tools --prefix=/opt/wine \
      --disable-tests --enable-archs=aarch64 --without-x --without-wayland --without-freetype --without-vulkan \
      --without-gstreamer --without-alsa --without-pulse --without-oss --without-cups --without-dbus --without-sane \
      --without-gphoto --without-usb --without-udev --without-v4l2 --without-opencl --without-pcap --without-netapi \
      --without-krb5 --without-gssapi --without-gnutls --without-sdl --without-capi --without-fontconfig \
    && make -j"$(nproc)" && make install DESTDIR=/out \
    && rm -rf /out/opt/wine/include /out/opt/wine/share/man \
    && find /out/opt/wine/lib/wine/aarch64-unix -type f -name '*.so' -exec aarch64-linux-gnu-strip --strip-unneeded {} +

# ---------------------------------------------------------------------------------------------
# 4. Download: portable Wine for x86_64 (only used by the amd64 image)
# ---------------------------------------------------------------------------------------------
FROM --platform=$BUILDPLATFORM debian:${DEBIAN}-slim AS wine-amd64
ARG WINE_URL WINE_SHA256
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates xz-utils && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL --retry 5 --retry-all-errors -o /wine.tar.xz "$WINE_URL" && echo "$WINE_SHA256  /wine.tar.xz" | sha256sum -c - \
    && mkdir -p /out/opt/wine && tar -xf /wine.tar.xz -C /out/opt/wine --strip-components=1 && rm /wine.tar.xz \
    && rm -rf /out/opt/wine/include /out/opt/wine/share/man

# ---------------------------------------------------------------------------------------------
# 5. Runtime base, one per CPU
# ---------------------------------------------------------------------------------------------
FROM debian:${DEBIAN}-slim AS runtime-amd64
ARG SPEECH_PLATFORM_URL SPEECH_PLATFORM_SHA256
RUN apt-get update && apt-get install -y --no-install-recommends libfreetype6 libfontconfig1 curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=wine-amd64 /out/ /
ENV WINEDLLOVERRIDES="mscoree=d;mshtml=d;winemenubuilder.exe=d;msttsengine=n;mssps=n;sapi=n;msvcp_win=n,b" \
    SPEECH_PLATFORM_URL=${SPEECH_PLATFORM_URL} \
    SPEECH_PLATFORM_SHA256=${SPEECH_PLATFORM_SHA256}

FROM debian:${DEBIAN}-slim AS runtime-arm64
COPY --from=wine-arm64 /out/ /
ENV WINEDLLOVERRIDES="mscoree=d;mshtml=d;winemenubuilder.exe=d;msvcp_win=n;audioses=n;umpdc=n;msvcp110_win=n;wintypes=n"

# ---------------------------------------------------------------------------------------------
# 6. Final image
# ---------------------------------------------------------------------------------------------
FROM runtime-${TARGETARCH}
ARG TARGETARCH VERSION
LABEL org.opencontainers.image.title="TuxAna" \
      org.opencontainers.image.description="Microsoft Ana (Cortana, es-ES) as a Wyoming TTS server; bring your own Windows files" \
      org.opencontainers.image.source="https://github.com/fernando433566/TuxAna" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${VERSION}"
COPY --from=rust /out/windows /opt/ana/windows
COPY --from=rust /out/tuxana /opt/ana/tuxana
COPY windows-files/manifests /opt/ana/manifests
COPY docker/${TARGETARCH}/ /opt/ana/
COPY docker/entrypoint.sh /opt/ana/

ENV PATH=/opt/wine/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    WINEPREFIX=/data/prefix \
    WINEDEBUG=-all \
    ANA_WINE=/opt/wine/bin/wine \
    ANA_ENGINE_EXE=/opt/ana/windows/ana-engine.exe

VOLUME /data
EXPOSE 10200
ENTRYPOINT ["/opt/ana/entrypoint.sh"]
CMD ["--uri", "tcp://0.0.0.0:10200"]
