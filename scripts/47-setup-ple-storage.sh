#!/usr/bin/env bash
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${root}/lib/common.sh"
: "${PLE_STORAGE_IMAGE:=/srv/llm/ple-nvme.ext4}"
: "${PLE_STORAGE_MOUNT:=/srv/llm/ple-ext4}"
: "${PLE_STORAGE_SIZE_GB:=110}"
command -v mountpoint >/dev/null || { log 'mountpoint is required'; exit 1; }
command -v mkfs.ext4 >/dev/null || { log 'e2fsprogs/mkfs.ext4 is required'; exit 1; }
if [[ ! -f "${PLE_STORAGE_IMAGE}" ]]; then
  log "Creating sparse ext4 PLE image (${PLE_STORAGE_SIZE_GB} GiB): ${PLE_STORAGE_IMAGE}"
  sudo truncate -s "${PLE_STORAGE_SIZE_GB}G" "${PLE_STORAGE_IMAGE}"
  sudo mkfs.ext4 -F -L llm-ple "${PLE_STORAGE_IMAGE}"
fi
sudo install -d -m 0777 "${PLE_STORAGE_MOUNT}"
if ! mountpoint -q "${PLE_STORAGE_MOUNT}"; then
  sudo mount -o loop,noatime "${PLE_STORAGE_IMAGE}" "${PLE_STORAGE_MOUNT}"
fi
# Keep the loop mount across reboots.  The entry is deliberately nofail so a
# missing/unavailable SSD image does not block the host boot.
fstab_line="${PLE_STORAGE_IMAGE} ${PLE_STORAGE_MOUNT} ext4 loop,noatime,nofail,x-systemd.automount 0 0"
if ! grep -Fqx -- "${fstab_line}" /etc/fstab 2>/dev/null; then
  printf '%s\n' "${fstab_line}" | sudo tee -a /etc/fstab >/dev/null
fi
findmnt -T "${PLE_STORAGE_MOUNT}" -o TARGET,SOURCE,FSTYPE,OPTIONS
log "PLE storage ready at ${PLE_STORAGE_MOUNT}"
