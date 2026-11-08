#!/usr/bin/env bash
# Copia los ficheros de Microsoft Ana a windows-files/files/ desde tu propio Windows, y comprueba su SHA-256.
#
#   ./collect.sh [--arm64] [--win11] ORIGEN
#
# ORIGEN puede ser:
#   usuario@ip-de-windows [puerto-ssh]   por SSH (OpenSSH Server de Windows)
#   /mnt/windows                         un disco o copia de Windows montado (la raíz de C:\)
#   --iso imagen.iso                     una ISO de instalación de Windows (necesita 7z y unos 8 GB libres de forma temporal)
#
# Por defecto usa Windows 10 x86-64. --arm64 elige los DLL de ARM64 y --win11 los de Windows 11.
# Con --win11, un fichero con otro hash se acepta y se asume que es de Windows 11 o superior; solo falla si falta.
#
# Son ficheros de Microsoft: cópialos solo de tu propio Windows y no los publiques.
set -euo pipefail
cd "$(dirname "$0")"
ARCH=x64; VER=win10; ISO=""
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --arm64) ARCH=arm64; shift ;;
    --win11) VER=win11; shift ;;
    --iso)   ISO="${2:?falta la ruta de la ISO}"; shift 2 ;;
    *) echo "opción desconocida: $1" >&2; exit 2 ;;
  esac
done
MANIFEST="manifests/manifest-$VER-$ARCH.tsv"

SOURCE="${1:-}"; PORT="${2:-22}"
TMP=""
cleanup() { [[ -z "$TMP" ]] || rm -rf "$TMP"; }
trap cleanup EXIT

if [[ -n "$ISO" ]]; then
  command -v 7z >/dev/null || { echo "Hace falta 7z para leer la ISO" >&2; exit 1; }
  TMP="$(mktemp -d -p . .iso-tmp.XXXXXX)"
  echo "Extrayendo la imagen de instalación de la ISO (tarda unos minutos)..."
  WIM="$(7z l -ba "$ISO" 'sources/install.*' | awk '{print $NF}' | head -1)"
  [[ -n "$WIM" ]] || { echo "No se encuentra sources/install.wim en la ISO" >&2; exit 1; }
  7z e -y -bso0 -bsp0 -o"$TMP" "$ISO" "$WIM"
  # Dentro de la imagen las mayúsculas varían entre versiones de Windows: buscamos sin distinguirlas
  grep -v '^#' "$MANIFEST" | cut -f1 | sed 's/^C:\\/1\//; s/\\/\//g' | tr 'A-Z' 'a-z' > "$TMP/wanted"
  7z l -ba "$TMP/$(basename "$WIM")" | awk 'NR==FNR { w[$0]=1; next } { p=$NF; if (tolower(p) in w) print p }' "$TMP/wanted" - > "$TMP/found"
  7z x -y -bso0 -bsp0 -o"$TMP/x" "$TMP/$(basename "$WIM")" -i@"$TMP/found"
  rm -f "$TMP/$(basename "$WIM")"
  SOURCE="$TMP/x/1"
fi
[[ -n "$SOURCE" ]] || { sed -n '4,11p' "$0" | sed 's/^# \?//' >&2; exit 2; }

rm -rf files.tmp
failed=0
while IFS=$'\t' read -r windows_path dest size sha256; do
  [[ "$windows_path" == \#* || -z "$windows_path" ]] && continue
  mkdir -p "files.tmp/$(dirname "$dest")"
  relative="${windows_path#C:\\}"              # Windows\Speech_OneCore\...
  relative="${relative//\\//}"                 # Windows/Speech_OneCore/...
  if [[ -d "$SOURCE" ]]; then
    # búsqueda sin distinguir mayúsculas: Windows no siempre escribe los nombres igual
    found="$(find "$SOURCE" -ipath "${SOURCE%/}/$relative" -print -quit)"
    [[ -n "$found" ]] && cp "$found" "files.tmp/$dest"
  else
    # -O: protocolo SCP clásico; con SFTP el OpenSSH de Windows trunca algunos ficheros
    scp -q -O -P "$PORT" "$SOURCE:C:/$relative" "files.tmp/$dest" || true
  fi
  if [[ -f "files.tmp/$dest" ]] && echo "$sha256  files.tmp/$dest" | sha256sum -c --status; then
    echo "  ok        $dest"
  elif [[ "$VER" == win11 && -s "files.tmp/$dest" ]]; then
    echo "  otro hash $dest  (se asume Windows 11 o superior)"
  else
    echo "  DISTINTO  $dest  (falta, está incompleto o es de otra versión de Windows; con Windows 11 o superior usa --win11)" >&2
    failed=1
  fi
done < "$MANIFEST"

if [[ $failed -ne 0 ]]; then
  echo "Algunos ficheros no coinciden con $MANIFEST. Se guardan en files.tmp/ para revisarlos." >&2
  exit 1
fi
rm -rf files && mv files.tmp files
echo "windows-files/files listo ($(du -sh files | cut -f1)) para $VER $ARCH"
