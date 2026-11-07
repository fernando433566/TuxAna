# TuxAna 🐧 — la voz de Cortana en Linux

**TuxAna** pone a hablar en Linux a **Microsoft Ana**, la voz española (España) de Cortana en Windows 10, como
servidor de texto a voz con el **protocolo Wyoming**, el mismo que usa `wyoming-piper` en Home Assistant.

No es una imitación ni un modelo entrenado: ejecuta el **motor original de Windows 10** dentro de Wine. El audio
es **idéntico al de Windows** (verificado muestra a muestra; ver [docs/TECNICO.md](docs/TECNICO.md)).

| Arquitectura | Cómo se ejecuta | Motor listo en | Cada frase |
|---|---|---|---|
| `linux/amd64` | Wine nativo | ~0,3 s | 10–40 ms |
| `linux/arm64` (Raspberry Pi 4/5…) | Wine x86_64 sobre el emulador **box64** | ~60 s | 0,1–0,3 s |

Imagen Docker (amd64 + arm64): [`ghcr.io/fernando433566/tuxana`](https://github.com/fernando433566/TuxAna/pkgs/container/tuxana) · Licencia: [MIT](LICENSE)

> ⚠️ **Necesitas un Windows 10 propio.** Los ficheros de la voz y del motor son de Microsoft. **No están en este
> repositorio ni en las imágenes**: un script los copia de tu Windows (ver [windows-files/](windows-files/README.md)).

## Inicio rápido

```bash
git clone https://github.com/fernando433566/TuxAna.git && cd TuxAna

# 1. Copia los 24 ficheros de Ana desde tu Windows 10 (por SSH o desde el disco montado). Se verifican por SHA-256.
windows-files/collect.sh usuario@ip-de-windows

# 2. Arranca. Descarga la imagen de GHCR (amd64 o arm64, según tu máquina).
docker compose up -d
docker logs -f tuxana        # espera a ver "[engine] ready after ..."
```

En Home Assistant: *Ajustes → Dispositivos y servicios → Añadir integración → **Wyoming Protocol***,
host = IP de la máquina y puerto `10200`. Después elige la voz `es_ES-ana` en tu asistente de voz.

El **primer arranque** crea el prefijo de Wine en el volumen `tuxana-data`: comprueba los ficheros de Windows,
descarga de Microsoft el runtime de Speech Platform 11, instala y registra la voz. Tarda ~1 min en x86_64 y unos
minutos en una Raspberry Pi. Los siguientes arranques lo reutilizan.

### Opciones

Se configuran como variables de entorno (en `docker-compose.yml`) o como argumentos del servidor:

| Variable | Argumento | Por defecto | |
|---|---|---|---|
| `WYOMING_URI` | `--uri` | `tcp://0.0.0.0:10200` | dónde escuchar |
| `ANA_RATE` | `--rate` | `0` | velocidad −10…10 (0 = exactamente como Windows) |
| `ANA_SAMPLE_RATE` | `--sample-rate` | `22050` | Hz del audio (PCM 16 bits mono) |
| `ANA_SAMPLES_PER_CHUNK` | `--samples-per-chunk` | `1024` | tamaño de cada `audio-chunk` |

Para rehacer el prefijo de Wine: `docker compose down && docker volume rm tuxana_tuxana-data`.

### Protocolo Wyoming soportado

`describe` → `info` · `synthesize` (texto completo; también `text_format: "ssml"`) → `audio-start`,
`audio-chunk`…, `audio-stop` · streaming `synthesize-start` / `synthesize-chunk` / `synthesize-stop` → audio frase
a frase y `synthesize-stopped` (respuestas de un LLM) · `ping` → `pong`.

## Compilar

Todo se compila dentro de Docker. No necesitas Rust ni compiladores en tu máquina.

```bash
# Imagen para la máquina en la que estás (sustituye a la de GHCR en docker compose)
docker compose build                 # o: docker build -t ghcr.io/fernando433566/tuxana:latest .

# Desde un PC x86_64: las dos imágenes, los binarios y los checksums en dist/
docker run --privileged --rm tonistiigi/binfmt --install arm64   # una vez por arranque del PC (emulación ARM)
scripts/build-release.sh
```

`scripts/build-release.sh` deja en `dist/`:

| Ruta | Contenido |
|---|---|
| `dist/bin/windows/` | `ana-engine.exe` y `rmproxy.dll`, que se ejecutan dentro de Wine |
| `dist/bin/amd64/tuxana`, `dist/bin/arm64/tuxana` | El servidor Wyoming |
| `dist/images/tuxana-<versión>-{amd64,arm64}.tar` | Las imágenes Docker, para adjuntar a una Release (no van en git) |
| `dist/SHA256SUMS` | Checksums de todo lo anterior |

Para publicar en GHCR el paquete multi-arquitectura, con las etiquetas `latest` y la versión:
`scripts/publish-ghcr.sh` (requiere `docker login ghcr.io` con un token con permiso `write:packages`).

Para llevar una imagen a otra máquina sin registro, por ejemplo a la Raspberry Pi:
`docker load -i tuxana-<versión>-arm64.tar && docker tag tuxana:<versión>-arm64 tuxana:latest`.

La compilación es cruzada: Rust y box64 se compilan con la CPU del PC aunque el destino sea ARM. La emulación QEMU
solo se usa para los `apt-get` de la imagen arm64. También se puede compilar directamente en la Raspberry Pi con
`docker build`, pero es mucho más lento.

Sin Docker, el código Rust se compila así:

```bash
cd server && cargo build --release && cargo test                       # servidor (Linux)
rustup target add x86_64-pc-windows-gnu                                 # + mingw-w64 instalado
cd windows-side && cargo build --release --target x86_64-pc-windows-gnu # ana-engine.exe y rmproxy.dll
```

## Estructura del repositorio

```
server/            Servidor Wyoming (Rust, solo std + serde_json)
  src/main.rs        opciones y escucha TCP
  src/handler.rs     eventos de Wyoming de cada cliente
  src/engine.rs      el proceso ana-engine.exe (arranque, peticiones, reinicio)
  src/sentences.rs   corta en frases el texto que llega en streaming
  src/wyoming.rs     formato de los mensajes Wyoming
windows-side/      Programas que se ejecutan dentro de Wine (Rust → Windows x86_64)
  ana-engine/        carga Ana una vez y emite el audio en streaming por stdout
  rmproxy/           puente COM: sustituye a sapi_onecore.dll, que Wine no puede cargar
docker/            ana.reg (registro de la voz en Wine), init-prefix.sh (primer arranque), entrypoint.sh
windows-files/     Lista de ficheros de Windows necesarios (ruta en C:\, SHA-256, versiones) y collect.sh
scripts/           build-release.sh (binarios + imágenes en dist/), publish-ghcr.sh (publica en GHCR)
docs/TECNICO.md    Funcionamiento interno, verificación frente a Windows, problemas resueltos, versiones
Dockerfile         Una sola receta para amd64 y arm64 (versiones de Wine, box64 y Speech Platform fijadas)
docker-compose.yml Despliegue
```

## Versiones usadas

Windows 10 Home 22H2 (build 19045.6456) como origen de los ficheros de Ana · Microsoft Speech Platform Runtime 11.0 x64 ·
Wine 11.17 (Kron4ek, amd64-wow64) · box64 v0.4.5 (`b71b003`) · Rust 1.83 · Debian 12 · Docker 29 + buildx.
Detalles y checksums en [docs/TECNICO.md](docs/TECNICO.md#versiones-con-las-que-se-construyó-y-verificó) y
[windows-files/README.md](windows-files/README.md).

## Memoria en ARM

Wine + box64 + Ana necesitan unos 1,2–1,4 GB, y el primer arranque algo más. En una Raspberry Pi de 4 GB,
comprueba antes con `free -h` que haya al menos ~1,6 GB disponibles: si se queda sin memoria, **la Pi entera puede
bloquearse**. Raspberry Pi OS arranca con `cgroup_disable=memory`, así que `mem_limit` de Docker no tiene efecto
salvo que añadas `cgroup_enable=memory` a `/boot/firmware/cmdline.txt` y reinicies.

## Créditos

- [**Cortana-2-Ana**](https://github.com/hoksilato2/Cortana-2-Ana) de **hoksilato2**: descubrió que la voz de Cortana es
  *Microsoft Ana* y cómo habilitarla en Windows 10 para programas de terceros. Con él se detectó y activó la voz.
- [**wine-tts**](https://github.com/inteltryb93/wine-tts): la técnica para ejecutar voces OneCore en Wine (Speech Platform 11
  más el puente `rmproxy`, que TuxAna porta a Rust).
- [**Wyoming**](https://github.com/OHF-Voice/wyoming) y [**wyoming-piper**](https://github.com/OHF-Voice/wyoming-piper)
  (Open Home Foundation): el protocolo y el modelo de servidor TTS.
- [**Wine**](https://www.winehq.org/), con las compilaciones de [Kron4ek](https://github.com/Kron4ek/Wine-Builds), y
  [**box64**](https://github.com/ptitSeb/box64) de ptitSeb.
- [windows-rs](https://github.com/microsoft/windows-rs) y [serde_json](https://github.com/serde-rs/json).

Licencias y avisos completos en [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

## Licencia

El código de TuxAna se publica bajo la [licencia MIT](LICENSE). No incluye ni cubre los ficheros de Microsoft:
cada usuario los obtiene de su propio Windows 10, con su licencia de Windows.

## Notas

- La entonación es la del motor original, sin modificar. Por ejemplo, Ana usada desde SAPI no distingue
  «¿Cómo estás?» de «Cómo estás.»; en Windows 10 tampoco.
- Las imágenes no contienen software de Microsoft, así que se pueden publicar. Créditos y licencias de terceros
  (Wine, box64, wine-tts…) en [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
- Microsoft, Windows y Cortana son marcas de Microsoft. TuxAna no está afiliado a Microsoft.
