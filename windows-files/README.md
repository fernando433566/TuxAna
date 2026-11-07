# Ficheros de Windows necesarios

TuxAna ejecuta el **motor original de Windows 10**. Esos ficheros son de Microsoft, así que **no están en
este repositorio**: cada usuario los copia de su propio Windows con `collect.sh`, que los deja en
`windows-files/files/`. Esa carpeta está excluida en `.gitignore` y no se sube a GitHub. El contenedor la
monta en modo de solo lectura.

## Windows con el que se verificó

| | |
|---|---|
| Sistema | Windows 10 Home 22H2, build **19045.6456** (x64) |
| Paquetes de idioma | `Language.Speech~~~es-ES~0.0.1.0` y `Language.TextToSpeech~~~es-ES~0.0.1.0` (instalados) |
| Motor de voz | `MSTTSEngine_OneCore.dll` y `MSTTSLoc_OneCore.dll` **10.3.21207.0** |
| Runtime C++ | `msvcp110_win.dll` 10.0.19041.3636 |
| Voz | Microsoft Ana, `DataVersion` **11.0.2016.0129** (token `MSTTS_V110_esES_Ana`) |

`manifest.tsv` lista cada fichero con su ruta exacta en `C:\`, su tamaño y su SHA-256. `collect.sh` usa ese
listado y rechaza cualquier fichero que no coincida. Con otra build de Windows 10 los hashes pueden variar:
el script te avisará, y puede que funcione igual, pero solo esta combinación está verificada.

## Qué es cada fichero y dónde está en Windows

| Ruta en Windows | Qué es |
|---|---|
| `C:\Windows\System32\Speech_OneCore\Engines\TTS\MSTTSEngine_OneCore.dll` | El motor de síntesis OneCore (el que usaba Cortana) |
| `C:\Windows\System32\Speech_OneCore\Engines\TTS\MSTTSLoc_OneCore.dll` | Procesado de texto por idioma (normalización, pronunciación) |
| `C:\Windows\System32\msvcp110_win.dll` | Runtime C++ del que depende el motor (Wine no lo trae) |
| `C:\Windows\Speech_OneCore\Engines\TTS\es-ES\M3082Ana.*` (APM, BR2, INI, TON, bep, heq) | Modelo acústico y de prosodia de Ana (3082 = LCID de es-ES) |
| `C:\Windows\Speech_OneCore\Engines\TTS\es-ES\NUSData\M3082Ana.voiceAssistant.*` | Base de unidades de voz del dominio **voiceAssistant**, la de Cortana (obligatoria) |
| `C:\Windows\Speech_OneCore\Engines\TTS\es-ES\NUSData\M3082Ana.tbtdirection.*` | Base de unidades del dominio de navegación (indicaciones giro a giro) |
| `C:\Windows\Speech_OneCore\Engines\TTS\es-ES\MSTTSLocEsES.dat` / `.INI` | Datos lingüísticos del español de España (diccionario, reglas) |
| `C:\Windows\Speech_OneCore\Engines\TTS\es-ES\EsES.{Address,Computer,Name}.dat`, `esES.Message.dat` | Normalización de direcciones, términos informáticos, nombres y mensajes |
| `C:\Windows\Speech_OneCore\Engines\TTS\en-US\MSTTSLocEnUS.dat` | Datos lingüísticos de inglés: Ana los usa para palabras en inglés (`ExtraLanguages` de su INI) |

En total son 24 ficheros y 46 MB. Las demás voces de la carpeta `es-ES` (Helena, Laura, Pablo) no hacen falta.

Durante la síntesis el motor también busca ficheros opcionales que **no existen en ningún Windows 10**
(`*.ACD, *.CCT, *.DCT, *.PST, *.RAD, *.TUN, *.WVE0`, `M3082Ana.ABM/ATM/CMP/NNM/EFF/BR3`, variantes `EnUS`).
Se comprobó en todo el disco del PC de referencia que no existen. No faltan: el audio de Linux es idéntico al de Windows.

## Cómo conseguirlos

1. En Windows 10: *Configuración → Hora e idioma → Idioma → Español (España) → Opciones* e instala **Voz**
   (o en PowerShell como administrador:
   `Add-WindowsCapability -Online -Name Language.TextToSpeech~~~es-ES~0.0.1.0`).
   Ana se instala con el idioma aunque no aparezca en la lista de voces de Configuración. Si quieres usarla también
   en el propio Windows, [Cortana-2-Ana](https://github.com/hoksilato2/Cortana-2-Ana) de hoksilato2 la habilita
   para SAPI y programas de terceros. Con él se identificó la voz de Cortana para este proyecto.
2. Una de estas dos opciones:
   - **Por SSH** (recomendado). Activa *Configuración → Aplicaciones → Características opcionales → Servidor OpenSSH*
     y ejecuta en Linux: `./collect.sh usuario@ip-de-windows [puerto]`.
   - **Desde el disco**. Monta la partición de Windows en Linux (por ejemplo en `/mnt/windows`) y ejecuta
     `./collect.sh /mnt/windows`.

## Registro de Windows

En Windows, la voz está registrada en
`HKLM\SOFTWARE\Microsoft\Speech_OneCore\Voices\Tokens\MSTTS_V110_esES_Ana`
(`CLSID {179F3D56-1B0B-42B2-A962-59B7EF59FE1B}`, `VoicePath …\es-ES\M3082Ana`,
`LangDataPath …\es-ES\MSTTSLocesES.dat`). No hace falta copiar nada del registro: TuxAna crea el
equivalente en Wine con [`docker/ana.reg`](../docker/ana.reg). Allí el token va bajo
`Speech Server\v11.0`, porque en Linux el motor lo carga el runtime de Microsoft Speech Platform 11.
