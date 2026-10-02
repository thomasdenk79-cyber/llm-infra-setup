#!/usr/bin/env bash
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${root}/lib/common.sh"
[[ -f "${root}/config/host.env" ]] && source "${root}/config/host.env"
pool="${ZFS_POOL:-}"
if [[ -z "${pool}" ]]; then
  # Prefer the pool that already owns the /srv mount. This keeps a separate
  # model disk usable when the root pool is also present.
  srv_dataset="$(zfs list -H -o name,mountpoint 2>/dev/null | awk '$2 == "/srv" { print $1; exit }')"
  if [[ -n "${srv_dataset}" ]]; then
    pool="${srv_dataset%%/*}"
  else
    pools=( $(zpool list -H -o name) )
    ((${#pools[@]} == 1)) || { log 'Set ZFS_POOL explicitly when zero or multiple pools exist.'; exit 1; }
    pool="${pools[0]}"
  fi
fi
zpool list "${pool}" >/dev/null
# A previous installation may have created the model dataset on the root pool.
# Disable that old mount when a dedicated /srv pool is selected; keep its data
# intact and never destroy the dataset.
legacy_dataset="zpcachyos/llm/models"
if [[ "${pool}" != "zpcachyos" ]] && zfs list -H -o name "${legacy_dataset}" >/dev/null 2>&1; then
  sudo zfs set mountpoint=none "${legacy_dataset}"
  sudo zfs set canmount=off "${legacy_dataset}"
  sudo zfs unmount "${legacy_dataset}" 2>/dev/null || true
fi
dataset="${pool}/llm/models"
parent="${pool}/llm"
# Keep model and service data on the broadly compatible lz4 compressor. This
# avoids requiring an optional pool compression feature when rebuilding a host
# from the repository.
if ! zfs list -H -o name "${parent}" >/dev/null 2>&1; then
  sudo zfs create -o mountpoint=none "${parent}"
fi
if ! zfs list -H -o name "${dataset}" >/dev/null 2>&1; then
  sudo zfs create -o mountpoint=/srv/llm/models -o compression=lz4 -o atime=off -o recordsize=1M "${dataset}"
else
  log "Dataset ${dataset} already exists; preserving its properties."
fi
# Keep the dedicated service tree on the safe, pool-compatible compressor.
if zfs list -H -o name "${pool}/srv" >/dev/null 2>&1; then
  sudo zfs set compression=lz4 "${pool}/srv"
fi
sudo zfs set compression=lz4 "${dataset}"
sudo zfs mount "${dataset}" 2>/dev/null || true
sudo install -d -m 0755 /srv/llm/cache/pennyroyal /srv/llm/nixl
# Convenience link for interactive users; data remains on the ZFS dataset.
install -d -m 0755 "${HOME}/llm"
ln -sfn /srv/llm/models "${HOME}/llm/models"
zfs get -H -o property,value mountpoint,compression,atime,recordsize "${dataset}"
log "Model dataset ready at /srv/llm/models"
