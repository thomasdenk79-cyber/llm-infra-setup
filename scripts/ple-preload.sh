#!/usr/bin/env bash
# PLE-Tabelle in den Seitenspeicher des Hosts lesen (Vorwuermen).
#
# Die Tabelle liegt auf SSD, wird aber von Linux im Seitenspeicher gehalten.
# Nach einem Neustart ist sie dort leer und die ersten Anfragen sind langsam.
# Dieses Skript liest sie einmal durch, damit der Wärmeprozess nicht der
# erste Nutzer bezahlt.
#
#   ./scripts/ple-preload.sh              vorladen (ionice, Hintergrund-freundlich)
#   ./scripts/ple-preload.sh --status     wie viel liegt bereits im Seitenspeicher?
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${root}/lib/common.sh"
[[ -f "${root}/config/host.env" ]] && source "${root}/config/host.env"
: "${PENNY_PLE_NVME_MODEL:=/srv/llm/ple-native/Qwen3.8-Flash-Next-PLE-NVME}"

if [[ ! -d "${PENNY_PLE_NVME_MODEL}" ]]; then
  echo "FEHLT: Ordner nicht gefunden: ${PENNY_PLE_NVME_MODEL}" >&2
  echo 'Pfad pruefen: grep PENNY_PLE config/host.env   (ggf. ./scripts/49-migrate-ple.sh)' >&2
  exit 1
fi

if [[ "${1:-}" == "--status" ]]; then
  PLE_DIR="${PENNY_PLE_NVME_MODEL}" python3 "${root}/scripts/lib/page_cache_status.py"
  exit $?
fi

avail_kb="$(awk '/MemAvailable/ {print $2}' /proc/meminfo)"
size_kb="$(du -sk --apparent-size "${PENNY_PLE_NVME_MODEL}" | awk '{print $1}')"
if (( size_kb > avail_kb )); then
  echo 'Hinweis: Die Tabelle (${size_kb} KiB) ist groesser als der verfuegbare Speicher'
  echo "         (${avail_kb} KiB). Es wird so viel vorgeladen, wie passt - der Rest"
  echo '         kommt bei Bedarf von der SSD.'
fi
log "Lade ${PENNY_PLE_NVME_MODEL} in den Seitenspeicher ..."
find "${PENNY_PLE_NVME_MODEL}" -maxdepth 1 -name '*.safetensors' -print0 \
  | nice -n 19 ionice -c 3 xargs -0 -P 2 -I{} sh -c 'cat "{}" > /dev/null'
PLE_DIR="${PENNY_PLE_NVME_MODEL}" python3 "${root}/scripts/lib/page_cache_status.py" || true
log 'Vorladen beendet.'
