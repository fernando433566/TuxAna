#!/bin/sh
# Creates the Wine prefix with the Speech Platform runtime and Microsoft Ana.
# Runs once, on the container's first start (on a Raspberry Pi this takes a few minutes).
set -eu

A=/opt/ana
C="$WINEPREFIX/drive_c/windows"
MSI=/data/SpeechPlatformRuntime.msi

# Under box64 the `wine` launcher is sometimes killed (exit code 137) when Wine shuts its session down,
# even though the work is done. So we do not trust exit codes: we wait for Wine to finish and then
# check that each step really produced what it should.
wine_step() {
    wine "$@" || echo "[init] (wine $1 exited with code $?, checking the result)"
    wineserver --wait
}
must_exist() {
    [ -e "$1" ] || { echo "[init] ERROR: $1 is missing" >&2; exit 1; }
}

echo "[init] checking Ana's Windows files in $A/voice-files"
missing=0
while IFS="$(printf '\t')" read -r windows_path dest size sha256; do
    case "$windows_path" in "#"*|"") continue ;; esac
    if ! echo "$sha256  $A/voice-files/$dest" | sha256sum -c --status 2>/dev/null; then
        echo "[init] ERROR: $dest is missing or different (on Windows: $windows_path)" >&2
        missing=1
    fi
done < "$A/manifest.tsv"
if [ "$missing" -ne 0 ]; then
    echo "[init] Copy the files with windows-files/collect.sh and mount windows-files/files at $A/voice-files (see README)." >&2
    exit 1
fi

if ! echo "$SPEECH_PLATFORM_SHA256  $MSI" | sha256sum -c --status 2>/dev/null; then
    echo "[init] downloading the Microsoft Speech Platform 11 runtime from Microsoft"
    curl -fsSL -o "$MSI" "$SPEECH_PLATFORM_URL"
    echo "$SPEECH_PLATFORM_SHA256  $MSI" | sha256sum -c -
fi

echo "[init] creating the Wine prefix in $WINEPREFIX (first start only)"
rm -rf "$WINEPREFIX"
mkdir -p "$(dirname "$WINEPREFIX")"
wine_step wineboot --init
must_exist "$C/system32/kernel32.dll"

echo "[init] installing the Microsoft Speech Platform 11 runtime"
wine_step msiexec /i 'Z:\data\SpeechPlatformRuntime.msi' /qn
must_exist "$WINEPREFIX/drive_c/Program Files/Common Files/Microsoft Shared/Speech/Platform/v11.0/mssps.dll"

echo "[init] copying the OneCore engine, Ana's voice data and rmproxy.dll"
mkdir -p "$C/system32/speech_onecore/Engines/TTS" "$C/system32/speech_onecore/common" "$C/Speech_OneCore/Engines/TTS"
cp "$A/voice-files/engine/MSTTSEngine_OneCore.dll" "$A/voice-files/engine/MSTTSLoc_OneCore.dll" "$C/system32/speech_onecore/Engines/TTS/"
cp "$A/voice-files/engine/msvcp110_win.dll" "$C/system32/"
cp "$A/windows/rmproxy.dll" "$C/system32/speech_onecore/common/"
cp -r "$A/voice-files/tts/." "$C/Speech_OneCore/Engines/TTS/"

echo "[init] registering the voice"
wine_step reg import 'Z:\opt\ana\ana.reg'
grep -q 'MSTTS_V110_esES_Ana' "$WINEPREFIX/system.reg" || { echo "[init] ERROR: voice not registered" >&2; exit 1; }

touch "$WINEPREFIX/.ana-ready"
echo "[init] done"
