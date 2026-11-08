# Créditos y software de terceros

TuxAna (licencia MIT, ver [LICENSE](LICENSE)) existe gracias a estos proyectos.

## Proyectos en los que se basa (no incluidos)

| Proyecto | Qué aportó | Licencia |
|---|---|---|
| [**Cortana-2-Ana**](https://github.com/hoksilato2/Cortana-2-Ana) de **hoksilato2** | Mostró que la voz de Cortana es en realidad **Microsoft Ana** y cómo exponerla en Windows 10 (registro del token `MSTTS_V110_esES_Ana`) para usarla desde SAPI y programas de terceros. Con él se activó y localizó la voz en el Windows de referencia. A su vez se basa en [este hilo de Super User](https://superuser.com/questions/1141840/how-to-enable-microsoft-eva-cortanas-voice-on-windows-10) | GPL-3.0 (no se incluye código suyo) |
| [**wine-tts**](https://github.com/inteltryb93/wine-tts) | La técnica para ejecutar voces OneCore de Windows en Wine: el runtime de Speech Platform 11 más el puente `rmproxy`. Ver su aviso de licencia más abajo | MIT |
| [**Wyoming**](https://github.com/OHF-Voice/wyoming) (Open Home Foundation) | El protocolo que implementa `server/` | MIT |
| [**wyoming-piper**](https://github.com/OHF-Voice/wyoming-piper) (Open Home Foundation) | Referencia del comportamiento de un servidor TTS Wyoming: streaming por frases, `info`, trozos de 1024 muestras | MIT |

## Incluido en las imágenes Docker o en el código

| Componente | Uso en TuxAna | Licencia | Origen |
|---|---|---|---|
| Wine 11.17 | Ejecuta los programas de Windows: compilación de Kron4ek (`amd64-wow64`) en x86-64, compilado desde el código fuente en ARM64 | LGPL-2.1-or-later | https://www.winehq.org/ (código fuente: https://dl.winehq.org/wine/source/11.x/wine-11.17.tar.xz) · https://github.com/Kron4ek/Wine-Builds/releases/tag/11.17 |
| `windows`, `windows-core` 0.58 (crates de Rust) | COM/Win32 en `ana-engine` y `rmproxy` | MIT OR Apache-2.0 | https://github.com/microsoft/windows-rs |
| `serde_json` 1 (crate de Rust) | JSON del protocolo Wyoming | MIT OR Apache-2.0 | https://github.com/serde-rs/json |
| Debian 12 "bookworm" | Base de las imágenes | Varias (DFSG) | https://www.debian.org/ |

Herramientas de compilación (no se incluyen en las imágenes): [Rust](https://www.rust-lang.org/) 1.83,
[MinGW-w64](https://www.mingw-w64.org/), [llvm-mingw](https://github.com/mstorsjo/llvm-mingw) (Apache-2.0 / ISC) para Windows
ARM64 y [Docker Buildx](https://github.com/docker/buildx).

[box64](https://github.com/ptitSeb/box64) (MIT, de ptitSeb) hizo posible TuxAna 1.0.0 en ARM; desde 1.1.0 ya no se usa ni se incluye.

### wine-tts

`windows-side/rmproxy` es un port a Rust de `server/rmproxy.c` del proyecto **wine-tts**: la técnica de redirigir
las clases COM de `sapi_onecore.dll` al runtime de Speech Platform 11 y el léxico vacío. También vienen de él las
claves de registro de `docker/ana.reg` que registran el motor OneCore.

```
MIT License

Copyright (c) 2026 wine-tts contributors

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
documentation files (the "Software"), to deal in the Software without restriction, including without limitation
the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and
to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of
the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO
THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF
CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
IN THE SOFTWARE.
```

## NO incluido (software de Microsoft)

- **Ficheros de Microsoft Ana y del motor OneCore de Windows** (Windows 10 u 11, x86-64 o ARM64): no están en este
  repositorio ni en las imágenes. Cada usuario los copia de su propio Windows (`windows-files/collect.sh`) y se montan al ejecutar
  el contenedor. Su uso queda sujeto a la licencia de Windows de quien los copia.
- **Microsoft Speech Platform Runtime 11.0 (x64)**: solo en x86-64, el contenedor lo descarga de los servidores de Microsoft
  en el primer arranque y verifica su checksum. Su uso queda sujeto a la licencia de Microsoft.

Microsoft, Windows y Cortana son marcas de Microsoft Corporation. TuxAna es un proyecto independiente, no
afiliado ni respaldado por Microsoft.
