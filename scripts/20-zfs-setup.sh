#!/usr/bin/env bash
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${root}/lib/common.sh"
pool="${ZFS_POOL:-}"
if [[ -z "${pool}" ]]; then
  pools=( $(zpool list -H -o name) )
  ((${#pools[@]} == 1)) || { log 'Set ZFS_POOL explicitly when zero or multiple pools exist.'; exit 1; }
  pool="${pools[0]}"
fi
zpool list "${pool}" >/dev/null
dataset="${pool}/llm/models"
parent="${pool}/llm"
if ! zfs list -H -o name "${parent}" >/dev/null 2>&1; then
  sudo zfs create -o mountpoint=none "${parent}"
fi
if ! zfs list -H -o name "${dataset}" >/dev/null 2>&1; then
  sudo zfs create -o mountpoint=/srv/llm/models -o compression=zstd-9 -o atime=off -o recordsize=1M "${dataset}"
else
  log "Dataset ${dataset} already exists; preserving its properties."
fi
sudo zfs mount "${dataset}" 2>/dev/null || true
sudo install -d -m 0755 /srv/llm/cache/pennyroyal /srv/llm/nixl
zfs get -H -o property,value mountpoint,compression,atime,recordsize "${dataset}"
log "Model dataset ready at /srv/llm/models"
