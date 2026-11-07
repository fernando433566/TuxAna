# syntax=docker/dockerfile:1
#
# TuxAna: Microsoft Ana (Cortana's Spanish voice) as a Wyoming TTS server for Home Assistant.
#
#   linux/amd64  Wine runs natively.
#   linux/arm64  Wine (x86_64) runs through the box64 emulator.
#
# Everything that is compiled is cross-compiled on the build machine's own CPU (--platform=$BUILDPLATFORM),
# so the arm64 image can be built quickly on a PC. Wine itself is only started when the container runs:
# the first start creates the Wine prefix in /data (a volume), later starts reuse it.
#
# The image contains NO Microsoft files, so it can be published:
#   - Ana's files (from your own Windows, see windows-files/) are mounted read-only at /opt/ana/voice-files;
#   - the Microsoft Speech Platform 11 runtime is downloaded from Microsoft on the first start (checksum verified).

ARG DEBIAN=bookworm

# Same releases the project was developed and verified with.
ARG WINE_URL=https://github.com/Kron4ek/Wine-Builds/releases/download/11.17/wine-11.17-amd64-wow64.tar.xz
ARG WINE_SHA256=3211db09086bc6fbd769c0286f27790b32d6fc6fb0bc610dad6b59796f07d462
ARG SPEECH_PLATFORM_URL=https://download.microsoft.com/download/A/6/4/A64012D6-D56F-4E58-85E3-531E56ABC0E6/x64_SpeechPlatformRuntime/SpeechPlatformRuntime.msi
ARG SPEECH_PLATFORM_SHA256=9c0a1d096e80f2ae77d5fc00b5d1a43b665c28ec6196911de3dce6d74c115137
ARG BOX64_COMMIT=b71b00322ec41fa49ea0c2e0a466424433622ca4

# ---------------------------------------------------------------------------------------------
# 1. Rust: the Wyoming server (for the target CPU) and the Windows programs (always x86_64 Windows)
# ---------------------------------------------------------------------------------------------
FROM --platform=$BUILDPLATFORM rust:1.83-${DEBIAN} AS rust
ARG TARGETARCH BUILDARCH
# mingw builds the Windows programs; a cross C linker is only needed when the target CPU differs from ours.
RUN apt-get update && apt-get install -y --no-install-recommends gcc-mingw-w64-x86-64 \
    && if [ "$TARGETARCH" != "$BUILDARCH" ]; then case "$TARGETARCH" in \
         arm64) apt-get install -y --no-install-recommends gcc-aarch64-linux-gnu libc6-dev-arm64-cross ;; \
         amd64) apt-get install -y --no-install-recommends gcc-x86-64-linux-gnu libc6-dev-amd64-cross ;; \
       esac; fi \
    && rm -rf /var/lib/apt/lists/* \
    && rustup target add x86_64-pc-windows-gnu x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu
ENV CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER=aarch64-linux-gnu-gcc \
    CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER=x86_64-linux-gnu-gcc
WORKDIR /src
COPY windows-side windows-side
RUN cd windows-side && cargo build --release --target x86_64-pc-windows-gnu \
    && mkdir -p /out/windows && cp target/x86_64-pc-windows-gnu/release/ana-engine.exe target/x86_64-pc-windows-gnu/release/rmproxy.dll /out/windows/
COPY server server
RUN case "$TARGETARCH" in amd64) T=x86_64-unknown-linux-gnu;; arm64) T=aarch64-unknown-linux-gnu;; *) echo "unsupported $TARGETARCH"; exit 1;; esac \
    && cd server && cargo build --release --target $T && cp target/$T/release/tuxana /out/

# Only the compiled programs, for `docker buildx build --target binaries -o type=local,dest=...` (scripts/build-release.sh)
FROM scratch AS binaries
COPY --from=rust /out/ /

# ---------------------------------------------------------------------------------------------
# 2. box64 (only used by the arm64 image), cross-compiled
# ---------------------------------------------------------------------------------------------
FROM --platform=$BUILDPLATFORM debian:${DEBIAN} AS box64
ARG BOX64_COMMIT BUILDARCH
RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates cmake make python3 \
    && if [ "$BUILDARCH" = arm64 ]; then apt-get install -y --no-install-recommends gcc; \
       else apt-get install -y --no-install-recommends gcc-aarch64-linux-gnu libc6-dev-arm64-cross; fi \
    && rm -rf /var/lib/apt/lists/*
RUN git clone https://github.com/ptitSeb/box64.git /box64 && cd /box64 && git checkout ${BOX64_COMMIT} \
    && mkdir build && cd build \
    && cmake .. -DARM64=1 -DARM_DYNAREC=ON -DCMAKE_BUILD_TYPE=RelWithDebInfo \
         -DCMAKE_C_COMPILER=aarch64-linux-gnu-gcc -DCMAKE_ASM_COMPILER=aarch64-linux-gnu-gcc \
    && make -j"$(nproc)" \
    && mkdir -p /out/usr/local/bin /out/usr/lib/box64-x86_64-linux-gnu /out/etc \
    && cp box64 /out/usr/local/bin/ \
    && cp ../x64lib/libstdc++.so.6 ../x64lib/libgcc_s.so.1 /out/usr/lib/box64-x86_64-linux-gnu/ \
    && cp ../system/box64.box64rc /out/etc/

# ---------------------------------------------------------------------------------------------
# 3. Download: portable Wine (checksum verified)
# ---------------------------------------------------------------------------------------------
FROM --platform=$BUILDPLATFORM debian:${DEBIAN}-slim AS downloads
ARG WINE_URL WINE_SHA256
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates xz-utils && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL -o /wine.tar.xz "$WINE_URL" && echo "$WINE_SHA256  /wine.tar.xz" | sha256sum -c - \
    && mkdir /opt/wine && tar -xf /wine.tar.xz -C /opt/wine --strip-components=1 && rm /wine.tar.xz \
    && rm -rf /opt/wine/include /opt/wine/share/man

# ---------------------------------------------------------------------------------------------
# 4. Runtime base, one per CPU. Both end up with a /usr/local/bin/wine and /usr/local/bin/wineserver.
# ---------------------------------------------------------------------------------------------
FROM debian:${DEBIAN}-slim AS runtime-amd64
RUN apt-get update && apt-get install -y --no-install-recommends libfreetype6 libfontconfig1 curl ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && ln -s /opt/wine/bin/wine /usr/local/bin/wine && ln -s /opt/wine/bin/wineserver /usr/local/bin/wineserver

FROM debian:${DEBIAN}-slim AS runtime-arm64
COPY --from=box64 /out/ /
RUN apt-get update && apt-get install -y --no-install-recommends libfreetype6 libfontconfig1 curl ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && printf '#!/bin/sh\nexec box64 /opt/wine/bin/wine "$@"\n'       > /usr/local/bin/wine \
    && printf '#!/bin/sh\nexec box64 /opt/wine/bin/wineserver "$@"\n' > /usr/local/bin/wineserver \
    && chmod +x /usr/local/bin/wine /usr/local/bin/wineserver
ENV BOX64_LOG=0 BOX64_NOBANNER=1 BOX64_LD_LIBRARY_PATH=/opt/wine/lib/wine/x86_64-unix

# ---------------------------------------------------------------------------------------------
# 5. Final image
# ---------------------------------------------------------------------------------------------
FROM runtime-${TARGETARCH}
ARG SPEECH_PLATFORM_URL SPEECH_PLATFORM_SHA256
ARG VERSION=1.0.0
LABEL org.opencontainers.image.title="TuxAna" \
      org.opencontainers.image.description="Microsoft Ana (Cortana, es-ES) as a Wyoming TTS server; bring your own Windows files" \
      org.opencontainers.image.source="https://github.com/fernando433566/TuxAna" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${VERSION}"
COPY --from=downloads /opt/wine /opt/wine
COPY --from=rust /out/windows /opt/ana/windows
COPY --from=rust /out/tuxana /opt/ana/tuxana
COPY docker/ana.reg docker/init-prefix.sh docker/entrypoint.sh windows-files/manifest.tsv /opt/ana/

ENV WINEPREFIX=/data/prefix \
    WINEDEBUG=-all \
    WINEDLLOVERRIDES="mscoree=d;mshtml=d;winemenubuilder.exe=d;msttsengine=n;mssps=n;sapi=n" \
    ANA_WINE=/usr/local/bin/wine \
    ANA_ENGINE_EXE=/opt/ana/windows/ana-engine.exe \
    SPEECH_PLATFORM_URL=${SPEECH_PLATFORM_URL} \
    SPEECH_PLATFORM_SHA256=${SPEECH_PLATFORM_SHA256}

VOLUME /data
EXPOSE 10200
ENTRYPOINT ["/opt/ana/entrypoint.sh"]
CMD ["--uri", "tcp://0.0.0.0:10200"]
