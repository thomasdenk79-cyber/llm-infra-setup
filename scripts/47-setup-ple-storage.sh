#!/usr/bin/env bash
# Prepare the storage that holds the PLE (per-layer embedding) table.
#
# Two supported modes:
#   PLE_BLOCK_DEVICE=/dev/nvme1n1p1  -> use a real partition (fast, recommended)
#   default                          -> sparse ext4 image file on /srv (works,
#                                       but it is a loop device on top of ZFS)
#
# Usage:
#   ./scripts/47-setup-ple-storage.sh            create/mount and persist
#   ./scripts/47-setup-ple-storage.sh --verify   only check, do not change
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${root}/lib/common.sh"
[[ -f "${root}/config/host.env" ]] && source "${root}/config/host.env"
: "${PLE_STORAGE_IMAGE:=/srv/llm/ple-nvme.ext4}"
: "${PLE_STORAGE_MOUNT:=/srv/llm/ple-ext4}"
: "${PLE_STORAGE_SIZE_GB:=110}"
: "${PLE_BLOCK_DEVICE:=}"

verify_only=0
[[ "${1:-}" == "--verify" ]] && verify_only=1
need_cmd mountpoint 'Jetzt ausführen: make install'

fstab_fields() {
  if [[ -n "${PLE_BLOCK_DEVICE}" ]]; then
    printf '%s %s ext4 noatime,nofail,x-systemd.automount 0 2\n' "${PLE_BLOCK_DEVICE}" "${PLE_STORAGE_MOUNT}"
  else
    printf '%s %s ext4 loop,noatime,nofail,x-systemd.automount 0 2\n' "${PLE_STORAGE_IMAGE}" "${PLE_STORAGE_MOUNT}"
  fi
}

verify() {
  local rc=0 line
  line="$(fstab_fields)"
  if ! mountpoint -q "${PLE_STORAGE_MOUNT}"; then
    printf 'FEHLT: %s ist nicht eingehängt.\n' "${PLE_STORAGE_MOUNT}" >&2
    printf 'Jetzt ausführen: ./scripts/47-setup-ple-storage.sh\n' >&2
    return 1
  fi
  if ! grep -Fq -- "${PLE_STORAGE_MOUNT}" /etc/fstab; then
    printf 'FEHLT: %s steht nicht in /etc/fstab. Nach einem Neustart fehlt die\n' "${PLE_STORAGE_MOUNT}" >&2
    printf '       PLE-Datei und Pennyroyal startet nicht mehr.\n' >&2
    printf 'Jetzt ausführen: ./scripts/47-setup-ple-storage.sh\n' >&2
    rc=1
  else
    printf 'OK: fstab-Eintrag vorhanden\n'
  fi
  if ! findmnt -T "${PLE_STORAGE_MOUNT}" -o FSTYPE --noheadings | grep -qx ext4; then
    printf 'FEHLT: %s ist kein ext4 (PLE-Leser braucht io_uring auf ext4).\n' "${PLE_STORAGE_MOUNT}" >&2
    rc=1
  fi
  if [[ -d "${PLE_STORAGE_MOUNT}" ]] && ls "${PLE_STORAGE_MOUNT}" >/dev/null 2>&1; then
    printf 'OK: Inhalt lesbar (%d Einträge)\n' "$(ls -1 "${PLE_STORAGE_MOUNT}" 2>/dev/null | wc -l)"
  else
    printf 'FEHLT: Inhalt von %s ist nicht lesbar.\n' "${PLE_STORAGE_MOUNT}" >&2
    rc=1
  fi
  if [[ "$(findmnt -n -o SOURCE -T "${PLE_STORAGE_MOUNT}")" == /dev/loop* && -z "${PLE_BLOCK_DEVICE}" ]]; then
    printf 'HINWEIS: PLE läuft auf einer Loop-Datei im ZFS-Pool. Das funktioniert,\n'
    printf '         kostet aber Durchsatz. Besser: echte NVMe-Partition über\n'
    printf '         PLE_BLOCK_DEVICE=/dev/... setzen. Details: docs/performance.md\n'
  fi
  return "${rc}"
}

if [[ "${verify_only}" == 1 ]]; then
  verify
  log 'PLE-Speicherprüfung abgeschlossen.'
  exit 0
fi

if [[ -n "${PLE_BLOCK_DEVICE}" ]]; then
  [[ -b "${PLE_BLOCK_DEVICE}" ]] || { log "FEHLT: PLE_BLOCK_DEVICE=${PLE_BLOCK_DEVICE} ist kein Blockgerät."; exit 1; }
  if ! blkid "${PLE_BLOCK_DEVICE}" 2>/dev/null | grep -q 'TYPE="ext4"'; then
    log "Gerät ${PLE_BLOCK_DEVICE} hat kein ext4. Nichts wird automatisch formatiert."
    log "Jetzt manuell prüfen und dann ausführen: sudo mkfs.ext4 -L llm-ple ${PLE_BLOCK_DEVICE}"
    exit 1
  fi
  source_desc="${PLE_BLOCK_DEVICE}"
else
  if [[ ! -f "${PLE_STORAGE_IMAGE}" ]]; then
    log "Erzeuge sparse ext4-Datei (${PLE_STORAGE_SIZE_GB} GiB): ${PLE_STORAGE_IMAGE}"
    sudo truncate -s "${PLE_STORAGE_SIZE_GB}G" "${PLE_STORAGE_IMAGE}"
    sudo mkfs.ext4 -F -L llm-ple "${PLE_STORAGE_IMAGE}"
  fi
  source_desc="${PLE_STORAGE_IMAGE}"
fi

# Der Eigentruemer des Einhängepunkts ist der Betreiber, nicht root: so kann das
# Vorbereitungs-Skript die PLE-Tabelle anlegen, ohne weltweite Schreibrechte (0777).
sudo install -d -m 0755 "${PLE_STORAGE_MOUNT}"
if [[ "$(stat -c %u "${PLE_STORAGE_MOUNT}")" != "$(id -u)" ]]; then
  sudo chown "$(id -u):$(id -g)" "${PLE_STORAGE_MOUNT}"
fi
if ! mountpoint -q "${PLE_STORAGE_MOUNT}"; then
  if [[ -n "${PLE_BLOCK_DEVICE}" ]]; then
    sudo mount -o noatime "${PLE_BLOCK_DEVICE}" "${PLE_STORAGE_MOUNT}"
  else
    sudo mount -o loop,noatime "${PLE_STORAGE_IMAGE}" "${PLE_STORAGE_MOUNT}"
  fi
fi

# Persist across reboots. nofail keeps the host bootable when the disk is away.
line="$(fstab_fields)"
if ! grep -Fqx -- "${line}" /etc/fstab; then
  if grep -Fq -- "${PLE_STORAGE_MOUNT}" /etc/fstab; then
    log "WARNUNG: /etc/fstab enthält bereits einen anderen Eintrag für ${PLE_STORAGE_MOUNT}."
    log "         Bitte von Hand prüfen: grep '${PLE_STORAGE_MOUNT}' /etc/fstab"
  else
    printf '%s\n' "${line}" | sudo tee -a /etc/fstab >/dev/null
    log "fstab-Eintrag ergänzt: ${line}"
  fi
fi
sudo systemctl daemon-reload 2>/dev/null || true
findmnt -T "${PLE_STORAGE_MOUNT}" -o TARGET,SOURCE,FSTYPE,OPTIONS
verify
log "PLE-Speicher bereit: ${source_desc} -> ${PLE_STORAGE_MOUNT}"
