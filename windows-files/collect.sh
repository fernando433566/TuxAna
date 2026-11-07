#!/usr/bin/env bash
# Copia desde tu Windows 10 los ficheros de Microsoft Ana listados en manifest.tsv a windows-files/files/
# y comprueba que cada uno coincide (SHA-256) con los que se usaron para verificar TuxAna.
#
#   ./collect.sh usuario@ip-de-windows [puerto-ssh]    por SSH (OpenSSH Server de Windows)
#   ./collect.sh /mnt/windows                         desde un disco/copia de Windows montado (la raíz de C:\)
#
# Son ficheros de Microsoft: cópialos solo de tu propio Windows y no los publiques.
set -euo pipefail
cd "$(dirname "$0")"
SOURCE="${1:?uso: $0 usuario@ip-de-windows [puerto] | /ruta/a/C}"
PORT="${2:-22}"

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
    echo "  ok       $dest"
  else
    echo "  DISTINTO $dest  (falta, está incompleto o es de otra versión de Windows)" >&2
    failed=1
  fi
done < manifest.tsv

if [[ $failed -ne 0 ]]; then
  echo "Algunos ficheros no coinciden con manifest.tsv. Se guardan en files.tmp/ para revisarlos." >&2
  exit 1
fi
rm -rf files && mv files.tmp files
echo "windows-files/files listo ($(du -sh files | cut -f1))"
