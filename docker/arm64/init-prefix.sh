#!/bin/sh
# First start on ARM64: creates the Wine prefix and installs the ARM64 OneCore engine and Ana.
# The files may come from Windows 10 ARM or Windows 11 ARM; unknown hashes are assumed to be Windows 11 or later.
set -eu

A=/opt/ana
V="$A/voice-files"
C="$WINEPREFIX/drive_c/windows"
TTS="$C/system32/speech_onecore/engines/tts"
COMMON="$C/system32/speech_onecore/common"

# Wine can end with an error code even when its work is done: we check the result instead.
wine_step() {
    wine "$@" || echo "[init] (wine $1 exited with code $?, checking the result)"
    wineserver --wait
}

check_files() {
    ok=0
    while IFS="$(printf '\t')" read -r windows_path dest size sha256; do
        case "$windows_path" in "#"*|"") continue ;; esac
        echo "$sha256  $V/$dest" | sha256sum -c --status 2>/dev/null || ok=1
    done < "$1"
    return $ok
}

echo "[init] checking Ana's Windows files in $V"
if check_files "$A/manifests/manifest-win10-arm64.tsv"; then
    echo "[init] found the Windows 10 ARM files"
    windows=10
elif check_files "$A/manifests/manifest-win11-arm64.tsv"; then
    echo "[init] found the Windows 11 ARM files"
    windows=11
else
    missing=0
    while IFS="$(printf '\t')" read -r windows_path dest size sha256; do
        case "$windows_path" in "#"*|"") continue ;; esac
        if [ ! -s "$V/$dest" ]; then
            echo "[init] ERROR: $dest is missing (on Windows: $windows_path)" >&2
            missing=1
        fi
    done < "$A/manifests/manifest-win10-arm64.tsv"
    if [ "$missing" -ne 0 ]; then
        echo "[init] Copy the files with windows-files/collect.sh --arm64 and mount windows-files/files at $V (see README)." >&2
        exit 1
    fi
    echo "[init] unknown file hashes: assuming Windows 11 ARM or later"
    windows=11
fi

# Windows 11 24H2 and later need ARMv8.1 atomics (LSE); ARMv8.0 CPUs such as the Raspberry Pi 4 do not have them.
if [ "$windows" = 11 ] && ! grep -qw atomics /proc/cpuinfo; then
    echo "[init] WARNING: this CPU has no LSE atomics (ARMv8.0, e.g. Raspberry Pi 4): Windows 11 24H2+ DLLs will not run. Use the Windows 10 ARM files."
fi

echo "[init] creating the Wine prefix in $WINEPREFIX (first start only)"
rm -rf "$WINEPREFIX"
mkdir -p "$(dirname "$WINEPREFIX")"
wine_step wineboot --init
[ -e "$C/system32/kernel32.dll" ] || { echo "[init] ERROR: the Wine prefix was not created" >&2; exit 1; }

echo "[init] copying the ARM64 engine and Ana's voice data"
mkdir -p "$TTS" "$COMMON" "$C/Speech_OneCore/Engines/TTS"
cp "$V/engine/MSTTSEngine_OneCore.dll" "$V/engine/MSTTSLoc_OneCore.dll" "$TTS/"
cp "$V/engine/msvcp110_win.dll" "$V/engine/msvcp_win.dll" "$V/engine/audioses.dll" "$V/engine/umpdc.dll" "$V/engine/wintypes.dll" "$C/system32/"
cp -r "$V/common/." "$COMMON/"
cp -r "$V/tts/." "$C/Speech_OneCore/Engines/TTS/"

# Windows hides Ana (she was Cortana's voice): declare her next to the other Spanish voices
TOKENS="$COMMON/es-ES/tokens_TTS_es-ES.xml"
if ! grep -q MSTTS_V110_esES_Ana "$TOKENS"; then
    awk -v block="$A/ana-token.xml" '/<\/Tokens>/ { while ((getline line < block) > 0) print line } { print }' "$TOKENS" > "$TOKENS.new"
    mv "$TOKENS.new" "$TOKENS"
fi

echo "[init] registering the voice"
wine_step reg import 'Z:\opt\ana\ana.reg'
grep -qi 'Windows.Foundation.Collections.Detail.Vector' "$WINEPREFIX/system.reg" || { echo "[init] ERROR: the classes were not registered" >&2; exit 1; }

touch "$WINEPREFIX/.ana-ready"
echo "[init] done"
