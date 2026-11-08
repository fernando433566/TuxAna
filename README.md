# TuxAna 🐧 — la voz de Cortana en Linux

**TuxAna** pone a hablar en Linux a **Microsoft Ana**, la voz española (España) de Cortana en Windows, como
servidor de texto a voz con el **protocolo Wyoming**, el mismo que usa `wyoming-piper` en Home Assistant.

No es una imitación ni un modelo entrenado: ejecuta el **motor original de Windows** dentro de Wine. El audio es
**prácticamente idéntico al de Windows 10** (verificado muestra a muestra; ver [docs/TECNICO.md](docs/TECNICO.md)).

| Arquitectura | Cómo se ejecuta | Motor listo en | Memoria | Cada frase |
|---|---|---|---|---|
| `linux/amd64` | Wine + Microsoft Speech Platform 11 + motor x86-64 | ~0,3 s | — | 10–40 ms |
| `linux/arm64` | Wine compilado para ARM64 + motor ARM64 de Microsoft: **sin emulación** | ~3,4 s (Raspberry Pi 4) | ~97 MB | 0,07–0,18 s |

Imagen Docker (amd64 + arm64): [`ghcr.io/fernando433566/tuxana`](https://github.com/users/fernando433566/packages/container/package/tuxana) · Licencia: [MIT](LICENSE)

> ⚠️ **Necesitas ficheros de Windows.** Los DLL y los datos de la voz son de Microsoft. **No están en este
> repositorio ni en las imágenes**: un script los copia de tu Windows o de una ISO de instalación (ver
> [windows-files/](windows-files/README.md)).

## Inicio rápido

```bash
git clone https://github.com/fernando433566/TuxAna.git && cd TuxAna

# 1. Copia los ficheros de Windows. Elige UNA opción, según tu procesador:
windows-files/collect.sh usuario@ip-de-windows                 # x86-64, Windows 10 (por SSH)
windows-files/collect.sh --win11 usuario@ip-de-windows         # x86-64, Windows 11 (por SSH)
windows-files/collect.sh --arm64 --iso windows10-arm64.iso     # ARM64, Windows 10 (desde la ISO)
windows-files/collect.sh --arm64 --win11 --iso windows11-arm64.iso  # ARM64, Windows 11 (CPU ARMv8.1 o superior)

# 2. Arranca. Descarga la imagen de GHCR (amd64 o arm64, según tu máquina).
docker compose up -d
docker logs -f tuxana        # espera a ver "[engine] ready after ..."
```

En Home Assistant: *Ajustes → Dispositivos y servicios → Añadir integración → **Wyoming Protocol***,
host = IP de la máquina y puerto `10200`. Después elige la voz `es_ES-ana` en tu asistente de voz.

El **primer arranque** crea el prefijo de Wine en el volumen `tuxana-data`: comprueba los ficheros de Windows e
instala y registra la voz. En x86-64 descarga además de Microsoft el runtime de Speech Platform 11. Tarda alrededor
de 1 minuto en x86-64 y de 2 minutos en una Raspberry Pi 4. Los siguientes arranques lo reutilizan.

## Windows 10 o Windows 11

TuxAna acepta los DLL de Windows 10 (la opción de referencia) o los de Windows 11, y detecta por sus hashes cuáles
has montado. Si no reconoce los hashes, **asume que son de Windows 11 o superior** y continúa siempre que estén todos.

| Se ha probado con | x86-64 | ARM64 |
|---|---|---|
| **Windows 10 22H2** | ✔ referencia | ✔ en Raspberry Pi 4 real |
| **Windows 11 26H2** | ✔ | ✔ bajo emulación ARM (qemu); no en hardware real |

La imagen ARM de Windows 10 usada en las pruebas procede de
[archive.org/details/windows-10-22h2-arm64](https://archive.org/details/windows-10-22h2-arm64).

- **Raspberry Pi 4 y otros ARMv8.0: usa los DLL de Windows 10.** Los de Windows 11 (24H2 y posteriores) usan
  instrucciones atómicas LSE de ARMv8.1 y fallan en esas CPU; el contenedor avisa al arrancar. La Raspberry Pi 5 sí
  tiene LSE, pero no se ha podido probar.
- **Los DLL de Windows 11 x86-64 no aportan instrucciones nuevas** frente a los de Windows 10: el motor solo tiene
  implementaciones SSE3 (nivel x86-64-v2), sin AVX ni AVX-512, y no usa GPU. No hay mejora de velocidad medible.

## Opciones

Se configuran como variables de entorno (en `docker-compose.yml`) o como argumentos del servidor:

| Variable | Argumento | Por defecto | |
|---|---|---|---|
| `WYOMING_URI` | `--uri` | `tcp://0.0.0.0:10200` | dónde escuchar |
| `ANA_RATE` | `--rate` | `0` | velocidad −10…10 (0 = exactamente como Windows) |
| `ANA_SAMPLE_RATE` | `--sample-rate` | `22050` | Hz del audio (PCM 16 bits mono) |
| `ANA_SAMPLES_PER_CHUNK` | `--samples-per-chunk` | `1024` | tamaño de cada `audio-chunk` |

Para rehacer el prefijo de Wine (por ejemplo, al cambiar de DLL de Windows 10 a Windows 11):
`docker compose down && docker volume rm tuxana_tuxana-data`.

### Protocolo Wyoming soportado

`describe` → `info` · `synthesize` (texto completo; también `text_format: "ssml"`) → `audio-start`,
`audio-chunk`…, `audio-stop` · streaming `synthesize-start` / `synthesize-chunk` / `synthesize-stop` → audio frase
a frase y `synthesize-stopped` (respuestas de un LLM) · `ping` → `pong`.

## Compilar

Todo se compila dentro de Docker. No necesitas Rust ni compiladores en tu máquina.

```bash
# Imagen para la máquina en la que estás (sustituye a la de GHCR en docker compose)
docker compose build                 # o: docker build -t ghcr.io/fernando433566/tuxana:latest .

# Desde un PC x86-64: las dos imágenes, los binarios y los checksums en dist/
scripts/build-release.sh
```

`scripts/build-release.sh` deja en `dist/`:

| Ruta | Contenido |
|---|---|
| `dist/bin/windows-amd64/` | `ana-engine.exe` y `rmproxy.dll`, que se ejecutan dentro de Wine en x86-64 |
| `dist/bin/windows-arm64/` | `ana-engine.exe`, que se ejecuta dentro de Wine en ARM64 |
| `dist/bin/amd64/tuxana`, `dist/bin/arm64/tuxana` | El servidor Wyoming |
| `dist/images/tuxana-<versión>-{amd64,arm64}.tar` | Las imágenes Docker, para adjuntar a una Release (no van en git) |
| `dist/SHA256SUMS` | Checksums de todo lo anterior |

Para publicar en GHCR el paquete multi-arquitectura, con las etiquetas `latest` y la versión:
`scripts/publish-ghcr.sh` (requiere `docker login ghcr.io` con un token con permiso `write:packages`).

Para llevar una imagen a otra máquina sin registro, por ejemplo a la Raspberry Pi:
`docker load -i tuxana-<versión>-arm64.tar && docker tag tuxana:<versión>-arm64 ghcr.io/fernando433566/tuxana:latest`.

La compilación es cruzada: Rust y Wine para ARM64 se compilan con la CPU del PC aunque el destino sea ARM, así que la
imagen arm64 no necesita emulación para construirse. La primera compilación de Wine tarda unos 15 minutos.

Sin Docker, el código Rust se compila así (con `mingw-w64` para x86-64 y `llvm-mingw` para ARM64):

```bash
cd server && cargo build --release && cargo test                       # servidor (Linux)
cd windows-side && cargo build --release --target x86_64-pc-windows-gnu # ana-engine.exe y rmproxy.dll (x86-64)
cd windows-side && cargo build --release --target aarch64-pc-windows-gnullvm -p ana-engine   # ana-engine.exe (ARM64)
```

## Estructura del repositorio

```
server/            Servidor Wyoming (Rust, solo std + serde_json)
  src/main.rs        opciones y escucha TCP
  src/handler.rs     eventos de Wyoming de cada cliente
  src/engine.rs      el proceso ana-engine.exe (arranque, peticiones, reinicio)
  src/sentences.rs   corta en frases el texto que llega en streaming
  src/wyoming.rs     formato de los mensajes Wyoming
windows-side/      Programas que se ejecutan dentro de Wine (Rust → Windows x86-64 y ARM64)
  ana-engine/        carga Ana una vez y emite el audio en streaming por stdout
  rmproxy/           puente COM de x86-64: sustituye a sapi_onecore.dll, que Wine no puede cargar ahí
docker/            entrypoint.sh, y por arquitectura amd64/ y arm64/: registro de la voz y primer arranque
windows-files/     Manifiestos (ruta en C:\, SHA-256, versiones por Windows y CPU) y collect.sh
scripts/           build-release.sh (binarios + imágenes en dist/), publish-ghcr.sh (publica en GHCR)
docs/TECNICO.md    Funcionamiento interno, verificación frente a Windows, problemas resueltos, versiones
Dockerfile         Una sola receta para amd64 y arm64 (versiones de Wine, llvm-mingw y Speech Platform fijadas)
docker-compose.yml Despliegue
```

## Versiones usadas

Windows 10 22H2 y Windows 11 26H2 (x86-64 y ARM64) como origen de los ficheros · Microsoft Speech Platform Runtime 11.0
x64 · Wine 11.17 (compilación Kron4ek en x86-64, compilado desde el código fuente en ARM64) · llvm-mingw 20261020 ·
Rust 1.83 · Debian 12 · Docker 29 + buildx. Detalles y checksums en
[docs/TECNICO.md](docs/TECNICO.md#versiones-con-las-que-se-construyó-y-verificó) y [windows-files/README.md](windows-files/README.md).

## Mejora en ARM (desde 1.1.0)

Hasta la versión 1.0.0, la imagen ARM ejecutaba todo a través del emulador box64. Ahora Wine y el motor son ARM64
nativos. Medido en una Raspberry Pi 4 de 4 GB con los mismos servicios en marcha:

| | 1.0.0 (box64) | 1.1.0 (ARM64 nativo) |
|---|---|---|
| Primer arranque hasta voz lista | 385 s | **109 s** |
| Motor listo con el prefijo creado | 63 s | **3,4 s** |
| Memoria del contenedor | 1.323 MB | **97 MB** |
| Memoria disponible mínima en la Pi | 1.152 MB | **2.135 MB** |

## Créditos

- [**Cortana-2-Ana**](https://github.com/hoksilato2/Cortana-2-Ana) de **hoksilato2**: descubrió que la voz de Cortana es
  *Microsoft Ana* y cómo habilitarla en Windows 10 para programas de terceros. Con él se detectó y activó la voz.
- [**wine-tts**](https://github.com/inteltryb93/wine-tts): la técnica para ejecutar voces OneCore en Wine (Speech Platform 11
  más el puente `rmproxy`, que TuxAna porta a Rust).
- [**Wyoming**](https://github.com/OHF-Voice/wyoming) y [**wyoming-piper**](https://github.com/OHF-Voice/wyoming-piper)
  (Open Home Foundation): el protocolo y el modelo de servidor TTS.
- [**Wine**](https://www.winehq.org/), con las compilaciones de [Kron4ek](https://github.com/Kron4ek/Wine-Builds), y
  [**llvm-mingw**](https://github.com/mstorsjo/llvm-mingw) de mstorsjo para compilar para Windows ARM64.
- [**box64**](https://github.com/ptitSeb/box64) de ptitSeb hizo posible la primera versión en ARM.
- [windows-rs](https://github.com/microsoft/windows-rs) y [serde_json](https://github.com/serde-rs/json).

Licencias y avisos completos en [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

## Licencia

El código de TuxAna se publica bajo la [licencia MIT](LICENSE). No incluye ni cubre los ficheros de Microsoft:
cada usuario los obtiene de su propia copia de Windows, con su licencia de Windows.

## Notas

- La entonación es la del motor original, sin modificar. Por ejemplo, Ana usada desde SAPI no distingue
  «¿Cómo estás?» de «Cómo estás.»; en Windows tampoco.
- Las imágenes no contienen software de Microsoft, así que se pueden publicar.
- Microsoft, Windows y Cortana son marcas de Microsoft. TuxAna no está afiliado a Microsoft.
