# Ficheros de Windows necesarios

TuxAna ejecuta el **motor original de Windows**. Esos ficheros son de Microsoft, así que **no están en este
repositorio**: cada usuario los copia de su propio Windows o de una ISO de instalación con `collect.sh`, que los deja en
`windows-files/files/`. Esa carpeta está excluida en `.gitignore` y no se sube a GitHub. El contenedor la monta en modo
de solo lectura.

## Qué conjunto elegir

| Tu CPU | Recomendado | Comando |
|---|---|---|
| x86-64 | Windows 10 22H2 (referencia) | `./collect.sh usuario@ip-de-windows` |
| x86-64 | Windows 11 26H2 | `./collect.sh --win11 usuario@ip-de-windows` |
| ARM64 (incluida Raspberry Pi 4) | Windows 10 22H2 ARM | `./collect.sh --arm64 --iso windows10-arm64.iso` |
| ARM64 con ARMv8.1 o superior | Windows 11 26H2 ARM | `./collect.sh --arm64 --win11 --iso windows11-arm64.iso` |

`collect.sh` acepta como origen `usuario@ip [puerto]` (OpenSSH Server de Windows), una carpeta con una copia de `C:\`
o `--iso imagen.iso` (necesita `7z` y unos 8 GB libres de forma temporal).

La imagen ARM de Windows 10 usada en las pruebas procede de
[archive.org/details/windows-10-22h2-arm64](https://archive.org/details/windows-10-22h2-arm64). Necesitas una licencia
válida de Windows para usar sus ficheros.

**Hashes desconocidos.** Si los ficheros no coinciden con ningún manifiesto (por ejemplo, una versión posterior de
Windows), TuxAna **asume que son de Windows 11 o superior** y continúa, siempre que estén todos. Esas versiones no están
verificadas: si la voz falla o suena mal, usa los de Windows 10. `collect.sh` solo acepta hashes desconocidos con `--win11`.

**Raspberry Pi 4 y otras CPU ARMv8.0.** Los DLL de Windows 11 24H2 y posteriores usan instrucciones atómicas LSE
(ARMv8.1) y no funcionan en estas CPU: usa los de Windows 10. Si la CPU no las tiene, el contenedor te lo avisa al arrancar.

## Versiones probadas

| | Windows 10 22H2 x64 | Windows 11 26H2 x64 | Windows 10 22H2 ARM64 | Windows 11 26H2 ARM64 |
|---|---|---|---|---|
| Manifiesto en `manifests/` | `manifest-win10-x64.tsv` | `manifest-win11-x64.tsv` | `manifest-win10-arm64.tsv` | `manifest-win11-arm64.tsv` |
| Motor OneCore | 10.3.21207.0 | 10.3.21207.0 | 10.3.21207.0 | 10.3.21207.0 |
| Host de voz | Speech Platform 11 + `rmproxy` | Speech Platform 11 + `rmproxy` | `sapi_onecore.dll` ARM64 | `sapi_onecore.dll` ARM64 |
| Audio frente a Windows 10 x64 (dif. máxima de 32.768) | Referencia: ≤2 | ≤2 | ≤7 (SNR 77–84 dB) | ≤2 |
| Probado en | PC x86-64 | PC x86-64 | Raspberry Pi 4 real | Emulación ARM (qemu) |

El modelo de voz de Ana (`M3082Ana.*` y `NUSData/M3082Ana.*`) es idéntico bit a bit en los cuatro: solo varían los DLL y,
en Windows 11, los datos lingüísticos `MSTTSLocEsES.dat` y `MSTTSLocEnUS.dat`.

**Instrucciones de CPU y GPU.** Los DLL de Windows 11 x86-64 no aportan instrucciones nuevas: el motor solo incluye
implementaciones SSE3 (nivel x86-64-v2), sin AVX (v3) ni AVX-512 (v4), y no usa GPU. No hay diferencia de velocidad medible.

## Qué es cada fichero y dónde está en Windows

| Ruta en Windows | Qué es | Dónde se usa |
|---|---|---|
| `C:\Windows\System32\Speech_OneCore\Engines\TTS\MSTTSEngine_OneCore.dll` | El motor de síntesis OneCore | x64 y ARM64 |
| `C:\Windows\System32\Speech_OneCore\Engines\TTS\MSTTSLoc_OneCore.dll` | Procesado de texto por idioma | x64 y ARM64 |
| `C:\Windows\System32\msvcp110_win.dll` | Runtime C++ del motor | x64 y ARM64 |
| `C:\Windows\System32\msvcp_win.dll` | Runtime C++ del motor de Windows 11 y de `sapi_onecore` | Windows 11 x64 y ARM64 |
| `C:\Windows\System32\AudioSes.dll`, `umpdc.dll`, `WinTypes.dll` | Dependencias de `sapi_onecore` que Wine no trae o no implementa del todo | ARM64 |
| `C:\Windows\System32\Speech_OneCore\common\sapi_onecore.dll` | La SAPI de Windows | ARM64 |
| `C:\Windows\System32\Speech_OneCore\common\tokens.xml`, `es-ES\tokens_TTS_es-ES.xml` | Catálogo de voces que lee `sapi_onecore` | ARM64 |
| `C:\Windows\Speech_OneCore\Engines\TTS\es-ES\M3082Ana.*` (APM, BR2, INI, TON, bep, heq) | Modelo acústico y de prosodia de Ana (3082 = LCID de es-ES) | x64 y ARM64 |
| `C:\Windows\Speech_OneCore\Engines\TTS\es-ES\NUSData\M3082Ana.voiceAssistant.*` | Base de unidades de voz del dominio **voiceAssistant**, la de Cortana (obligatoria) | x64 y ARM64 |
| `C:\Windows\Speech_OneCore\Engines\TTS\es-ES\NUSData\M3082Ana.tbtdirection.*` | Base de unidades del dominio de navegación | x64 y ARM64 |
| `C:\Windows\Speech_OneCore\Engines\TTS\es-ES\MSTTSLocEsES.dat` / `.INI` | Datos lingüísticos del español de España | x64 y ARM64 |
| `C:\Windows\Speech_OneCore\Engines\TTS\es-ES\EsES.{Address,Computer,Name}.dat`, `esES.Message.dat` | Normalización de direcciones, términos informáticos, nombres y mensajes | x64 y ARM64 |
| `C:\Windows\Speech_OneCore\Engines\TTS\en-US\MSTTSLocEnUS.dat` | Datos de inglés: Ana los usa para palabras en inglés | x64 y ARM64 |

Durante la síntesis el motor también busca ficheros opcionales que **no existen en ningún Windows 10**
(`*.ACD, *.CCT, *.DCT, *.PST, *.RAD, *.TUN, *.WVE0`, `M3082Ana.ABM/ATM/CMP/NNM/EFF/BR3`, variantes `EnUS`). No hacen falta.

## Cómo conseguirlos desde un Windows instalado

1. En Windows: *Configuración → Hora e idioma → Idioma → Español (España) → Opciones* e instala **Voz**
   (o en PowerShell como administrador: `Add-WindowsCapability -Online -Name Language.TextToSpeech~~~es-ES~0.0.1.0`).
   Ana se instala con el idioma aunque no aparezca en la lista de voces. Si quieres usarla también en el propio Windows,
   [Cortana-2-Ana](https://github.com/hoksilato2/Cortana-2-Ana) de hoksilato2 la habilita para programas de terceros.
   Con él se identificó la voz de Cortana para este proyecto.
2. Activa *Configuración → Aplicaciones → Características opcionales → Servidor OpenSSH* y ejecuta `collect.sh`, o monta la
   partición de Windows en Linux y usa `./collect.sh /mnt/windows`.

En Windows la voz está registrada en
`HKLM\SOFTWARE\Microsoft\Speech_OneCore\Voices\Tokens\MSTTS_V110_esES_Ana`. No hace falta copiar nada del registro:
TuxAna crea lo necesario en Wine con `docker/amd64/ana.reg` y `docker/arm64/ana.reg`.
