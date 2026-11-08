#!/bin/sh
# Creates the Wine prefix with the Speech Platform runtime and Microsoft Ana.
# Runs once, on the container's first start (on a Raspberry Pi this takes a few minutes).
set -eu

A=/opt/ana
C="$WINEPREFIX/drive_c/windows"
MSI=/data/SpeechPlatformRuntime.msi

# Wine can exit with an error code even when its work is done. So we do not trust exit codes:
# we wait for Wine to finish and then check that each step really produced what it should.
wine_step() {
    wine "$@" || echo "[init] (wine $1 exited with code $?, checking the result)"
    wineserver --wait
}
must_exist() {
    [ -e "$1" ] || { echo "[init] ERROR: $1 is missing" >&2; exit 1; }
}

# check_files <manifest> [report]: are the mounted files exactly the ones listed in this manifest?
check_files() {
    ok=0
    while IFS="$(printf '\t')" read -r windows_path dest size sha256; do
        case "$windows_path" in "#"*|"") continue ;; esac
        if ! echo "$sha256  $A/voice-files/$dest" | sha256sum -c --status 2>/dev/null; then
            ok=1
            [ "${2:-}" = report ] && echo "[init] ERROR: $dest is missing or different (on Windows: $windows_path)" >&2
        fi
    done < "$1"
    return $ok
}

# The files may come from Windows 10 (the reference set) or Windows 11: both work the same.
echo "[init] checking Ana's Windows files in $A/voice-files"
if check_files "$A/manifests/manifest-win10-x64.tsv"; then
    echo "[init] found the Windows 10 files"
elif check_files "$A/manifests/manifest-win11-x64.tsv"; then
    echo "[init] found the Windows 11 files"
else
    # Unknown hashes are fine (a newer Windows than the ones we verified), as long as every file is there.
    missing=0
    while IFS="$(printf '\t')" read -r windows_path dest size sha256; do
        case "$windows_path" in "#"*|"") continue ;; esac
        if [ ! -s "$A/voice-files/$dest" ]; then
            echo "[init] ERROR: $dest is missing (on Windows: $windows_path)" >&2
            missing=1
        fi
    done < "$A/manifests/manifest-win10-x64.tsv"
    if [ "$missing" -ne 0 ]; then
        echo "[init] Copy the files with windows-files/collect.sh and mount windows-files/files at $A/voice-files (see README)." >&2
        exit 1
    fi
    echo "[init] unknown file hashes: assuming Windows 11 or later"
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
# Only the Windows 11 engine needs this one; Wine's built-in copy is used otherwise
[ ! -f "$A/voice-files/engine/msvcp_win.dll" ] || cp "$A/voice-files/engine/msvcp_win.dll" "$C/system32/"
cp "$A/windows/rmproxy.dll" "$C/system32/speech_onecore/common/"
cp -r "$A/voice-files/tts/." "$C/Speech_OneCore/Engines/TTS/"

echo "[init] registering the voice"
wine_step reg import 'Z:\opt\ana\ana.reg'
grep -q 'MSTTS_V110_esES_Ana' "$WINEPREFIX/system.reg" || { echo "[init] ERROR: voice not registered" >&2; exit 1; }

touch "$WINEPREFIX/.ana-ready"
echo "[init] done"
