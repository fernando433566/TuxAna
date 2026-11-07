# Cómo funciona TuxAna por dentro

## La cadena completa

```
Home Assistant
   │  protocolo Wyoming (TCP 10200): describe / synthesize / synthesize-start|chunk|stop / ping
   ▼
tuxana  (server/, Rust, Linux nativo)
   │  stdin:  [flags u32][longitud u32][texto UTF-8]
   │  stdout: "ANA1" READY  ·  AUDIO* (PCM 16 bits mono)  ·  DONE (HRESULT)
   ▼
wine (+ box64 en ARM)  ──►  ana-engine.exe  (windows-side/ana-engine, Rust → x86_64-pc-windows-gnu)
                                │  ISpVoice del Microsoft Speech Platform 11 (mssps.dll)
                                │  salida: ISpStream sobre un IStream propio que escribe cada trozo en stdout
                                ▼
                         MSTTSEngine_OneCore.dll  (el motor de Windows 10)
                                │  pide clases COM de sapi_onecore.dll ──► rmproxy.dll (windows-side/rmproxy)
                                │                                        └─► clases equivalentes de mssps.dll
                                ▼                                            + léxico de usuario vacío
                         datos de Ana: M3082Ana.*, NUSData/M3082Ana.voiceAssistant.*, MSTTSLocEsES.dat …
```

- **¿Por qué Speech Platform 11 y no SAPI de Windows?** El motor OneCore de Windows 10 es un motor SAPI. En Windows
  lo carga `sapi_onecore.dll`, que depende de piezas de Windows que Wine no tiene (UMPDC, AudioSes,
  WinRT…). El runtime de Microsoft Speech Platform 11 es un SAPI autónomo que sí funciona en Wine y acepta el
  mismo tipo de motor. Las pocas clases que el motor pide directamente a `sapi_onecore.dll` (gestor de
  recursos, conversores fonéticos, categorías de tokens, léxico) las sirve `rmproxy.dll`.
- **¿Por qué no el SAPI de Wine?** El SAPI integrado de Wine no implementa lo que necesitan los motores de
  Microsoft (`ISpTTSEngineSite::GetEventInterest` es un *stub*). Por eso `WINEDLLOVERRIDES` fuerza las versiones
  nativas (`msttsengine=n;mssps=n;sapi=n`).
- **Streaming real.** `ana-engine` no espera a que termine la frase: SAPI escribe en el `IStream` propio y cada
  escritura sale al momento como trama AUDIO. El servidor la reenvía como `audio-chunk` de Wyoming.
- **Un solo proceso del motor.** Arrancar Wine y cargar la voz cuesta ~0,3 s en x86_64 y ~60 s en una
  Raspberry Pi 4. Por eso el motor se arranca una vez y las peticiones se sirven en serie. Si el motor muere,
  la siguiente petición arranca otro.
- **Texto completo frente a streaming.** Con `synthesize`, el texto entero va al motor de una vez, igual que en
  Windows. En streaming (`synthesize-chunk`, típico de un LLM), `sentences.rs` espera a tener frases completas
  para no romper la entonación.

## Fidelidad con Windows: cómo se verificó

Se generaron las mismas frases en el Windows 10 de referencia (SAPI nativo) y en Linux, y se compararon
muestra a muestra:

| Comparación | Resultado |
|---|---|
| Linux (Wine + box64, Raspberry Pi 4) frente a Windows 10 nativo | Diferencia máxima de **2 LSB** (redondeo; inaudible). Correlación 0,99986 |
| box64 con *dynarec* frente a box64 intérprete puro | **Idénticos bit a bit** (la emulación de coma flotante no influye) |
| Contenedor amd64 (Wine nativo) frente a Linux en Raspberry Pi | **Idénticos bit a bit** |
| Contenedor arm64 en Raspberry Pi frente a Linux en Raspberry Pi | **Idénticos bit a bit** |
| `rmproxy` en Rust frente al `rmproxy` original en C | **Idénticos bit a bit** |

Frases de prueba: «Prueba 1: Ejecución en Linux, ¿cómo saldrá?», «¿Cómo estás?», «Cómo estás.»,
«¡Qué alegría verte!» y «Hola, soy Cortana. ¿En qué puedo ayudarte?».

Comportamientos que parecen fallos pero son del propio motor (en Windows ocurre igual):

- Usada desde SAPI, Ana genera exactamente el mismo audio para «¿Cómo estás?» que para «Cómo estás.».
- El dominio `voiceAssistant` (la base de Cortana) se carga siempre y es obligatorio: sin `NUSData` el motor
  falla con `0x80070002`. Las etiquetas SSML de dominio y las claves `NusRuntime.*` del INI no cambian el resultado.
  `NusRuntime.AllowDomainDetection=true` hace fallar la síntesis (`0x8004801c`).

## Problemas encontrados por el camino

| Síntoma | Causa | Solución |
|---|---|---|
| Las vocales con tilde se perdían («Ejecucie», «cemo») | Wine entregaba `argv` en CP-1252 y el programa lo leía como UTF-8 | Leer la línea de órdenes en UTF-16 (`GetCommandLineW`). En TuxAna el texto va por stdin en UTF-8 |
| La «referencia de Windows» sonaba distinta | El `.ps1` que la generó se guardó en UTF-8 sin BOM y PowerShell 5 lo leyó como CP-1252 | Los scripts para Windows se envían en UTF-16 |
| Se sospechaba que faltaban ficheros `.ACD/.CCT/.PST/.RAD/.TUN/.WVE0`… | El motor los busca, pero no existen en ningún Windows 10 | No hace falta nada: son sondeos opcionales |
| `scp` desde Windows dejaba ficheros de 200 KB | El servidor SFTP de OpenSSH para Windows truncaba las copias | `scp -O` (protocolo clásico); `collect.sh` además verifica el SHA-256 |
| El primer arranque en ARM abortaba con código 137 | Bajo box64, `wine wineboot` a veces termina con SIGKILL aunque haya acabado su trabajo | `init-prefix.sh` comprueba el resultado de cada paso en lugar del código de salida |
| La Raspberry Pi se bloqueó en una prueba | Sin memoria: el motor necesita ~1,2–1,4 GB y Raspberry Pi OS desactiva los límites de memoria de Docker (`cgroup_disable=memory`) | Comprobar `free -h` antes; ver «Memoria en ARM» en el README |

## Versiones con las que se construyó y verificó

| Pieza | Versión |
|---|---|
| Windows de origen de los ficheros | Windows 10 Home 22H2, build 19045.6456 (motor OneCore 10.3.21207.0, Ana DataVersion 11.0.2016.0129) |
| Microsoft Speech Platform Runtime | 11.0, x64 (`SpeechPlatformRuntime.msi`, SHA-256 `9c0a1d09…5137`) |
| Wine | 11.17, compilación de Kron4ek `amd64-wow64` (SHA-256 `3211db09…d462`) |
| box64 | v0.4.5, commit `b71b00322ec41fa49ea0c2e0a466424433622ca4`, `-DARM64=1 -DARM_DYNAREC=ON` |
| Rust | 1.83 (`windows`/`windows-core` 0.58, `serde_json` 1) |
| Imagen base | Debian 12 bookworm |
| Docker | Engine 29.x y buildx 0.38 (compilación cruzada con `tonistiigi/binfmt` para arm64) |
| Probado en | PC x86_64 (CachyOS) · Raspberry Pi 4 Model B 4 GB (Raspberry Pi OS bookworm, kernel 6.12) |
| Protocolo Wyoming | Especificación de `wyoming` 1.11 y del handler de `wyoming-piper` 2.5 |

Las URL y los checksums de Wine y Speech Platform, y el commit de box64, están fijados como `ARG` al principio del
`Dockerfile`.
