#!/bin/sh
# Container start: prepare the Wine prefix if this is the first start, then run the Wyoming server.
set -eu
[ -f "$WINEPREFIX/.ana-ready" ] || /opt/ana/init-prefix.sh
exec /opt/ana/tuxana "$@"
