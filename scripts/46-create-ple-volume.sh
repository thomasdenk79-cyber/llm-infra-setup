#!/usr/bin/env bash
# Native Blockflaeche fuer die PLE-Tabelle anlegen (zvol oder echte Partition).
#
# Hintergrund: Die erste Version legte eine ext4-Datei in eine Loop-Datei auf ZFS.
# Das funktionierte, war aber drei Schichten tief (io_uring -> ext4 -> loop -> ZFS).
# Diese Datei richtet stattdessen ein echtes Blockgeraet ein:
#
#   PLE_SOURCE=zvol    (Standard)  ZFS-Volumen auf dem vorhandenen /srv-Pool.
#                                  Grund: Die Scheibe ist ganz in zwei ZFS-Pools
#                                  aufgeteilt, und ein ZFS-Vdev laesst sich nicht
#                                  verkleinern. Eine neue Partition gaebe es nur
#                                  nach Platten-Tausch oder Neuinstallation.
#   PLE_SOURCE=block              Vorhandende Partition verwenden
#                                  (PLE_BLOCK_DEVICE=/dev/nvme1n1p1). Nichts wird
#                                  formatiert, ohne dass der Betreiber bestaetigt.
#
# Der Einhaengepunkt ist bewusst neu (/srv/llm/ple-native), damit der laufende
# Container an seinem bisherigen Platz in Ruhe weiterarbeitet.
#
# Verwendung:
#   ./scripts/46-create-ple-volume.sh              anlegen, formatieren, einhaengen
#   ./scripts/46-create-ple-volume.sh --verify     nur pruefen
#   ./scripts/46-create-ple-volume.sh --size 80    Groesse in GiB (Standard 80)
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${root}/lib/common.sh"
[[ -f "${root}/config/host.env" ]] && source "${root}/config/host.env"
: "${PLE_SOURCE:=zvol}"
: "${PLE_ZFS_PARENT:=}"
: "${PLE_ZFS_VOL:=ple-vol}"
: "${PLE_ZFS_SIZE_GB:=80}"
: "${PLE_NATIVE_MOUNT:=/srv/llm/ple-native}"
: "${PLE_BLOCK_DEVICE:=}"

verify_only=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --verify) verify_only=1; shift ;;
    --size) PLE_ZFS_SIZE_GB="$2"; shift 2 ;;
    *) printf 'unbekanntes Argument: %s (hilfe: --verify, --size GiB)\n' "$1" >&2; exit 2 ;;
  esac
done

# Zielgeraet bestimmen
if [[ "${PLE_SOURCE}" == block ]]; then
  device="${PLE_BLOCK_DEVICE}"
  [[ -b "${device}" ]] || { echo "FEHLT: PLE_BLOCK_DEVICE=${device} ist kein Blockgeraet." >&2; exit 1; }
  source_desc="${device}"
else
  parent="${PLE_ZFS_PARENT:-}"
  if [[ -z "${parent}" ]]; then
    srv_dataset="$(zfs list -H -o name,mountpoint 2>/dev/null | awk '$2 == "/srv" { print $1; exit }')"
    if [[ -n "${srv_dataset}" ]]; then parent="${srv_dataset}"; else parent="$(zpool list -H -o name | head -1)/srv"; fi
  fi
  vol="${parent}/${PLE_ZFS_VOL}"
  device="/dev/zvol/${vol}"
  source_desc="zvol ${vol}"
  zfs list -H -o name "${parent}" >/dev/null 2>&1 \
    || { echo "FEHLT: Eltern-Dataset ${parent} existiert nicht. PLE_ZFS_PARENT setzen." >&2; exit 1; }
fi

verify() {
  local rc=0
  if ! mountpoint -q "${PLE_NATIVE_MOUNT}"; then
    echo "FEHLT: ${PLE_NATIVE_MOUNT} ist nicht eingehaengt." >&2
    echo "Jetzt ausführen: ./scripts/46-create-ple-volume.sh" >&2
    return 1
  fi
  local src fstype
  src="$(findmnt -n -o SOURCE -T "${PLE_NATIVE_MOUNT}")"
  fstype="$(findmnt -n -o FSTYPE -T "${PLE_NATIVE_MOUNT}")"
  case "${src}" in
    /dev/loop*) echo "FEHLT: ${PLE_NATIVE_MOUNT} haengt an einer Loop-Datei (${src}); das war der alte Weg." >&2; rc=1 ;;
    *) echo "OK: echtes Blockgeraet ${src} (${fstype})" ;;
  esac
  grep -Fq -- "${PLE_NATIVE_MOUNT}" /etc/fstab \
    || { echo "FEHLT: kein fstab-Eintrag fuer ${PLE_NATIVE_MOUNT}." >&2; rc=1; }
  ls "${PLE_NATIVE_MOUNT}" >/dev/null 2>&1 \
    || { echo "FEHLT: Inhalt nicht lesbar." >&2; rc=1; }
  return "${rc}"
}
if [[ "${verify_only}" == 1 ]]; then
  verify
  exit $?
fi

# --- anlegen / vorbereiten ---------------------------------------------------
if [[ "${PLE_SOURCE}" != block ]]; then
  if ! zfs list -H -o name "${vol}" >/dev/null 2>&1; then
    log "Lege ${source_desc} an (${PLE_ZFS_SIZE_GB} GiB, duenn, ohne Rueckhalte-Reservierung)."
    sudo zfs create -V "${PLE_ZFS_SIZE_GB}G" \
      -o volblocksize=4K \
      -o refreservation=none \
      -o compression=off \
      -o primarycache=metadata \
      -o secondarycache=none \
      -o logbias=throughput \
      -o sync=disabled \
      "${vol}"
  else
    log "${vol} existiert bereits; Eigenschaften werden nur ergaenzt, Daten bleiben."
  fi
  # Eigenschaften idempotent nachziehen (nach einem Umbau oder einer aelteren Anlage).
# atime/recordsize entfallen: die Properties gelten fuer Dateisysteme, nicht fuer Volumen.
  sudo zfs set primarycache=metadata "${vol}" 2>/dev/null || true
  sudo zfs set secondarycache=none  "${vol}" 2>/dev/null || true
  sudo zfs set compression=off       "${vol}" 2>/dev/null || true
  sudo zfs set logbias=throughput    "${vol}" 2>/dev/null || true
fi

if ! sudo blkid "${device}" 2>/dev/null | grep -q 'TYPE="ext4"'; then
  cat >&2 <<MSG
Das Gerät ${device} enthaelt kein ext4.
Formatieren loescht alle Daten auf diesem Gerät. Deshalb wird hier NICHTS automatisch
formatiert. Wenn das Gerät frisch und leer ist, ausfuehren:

  sudo mkfs.ext4 -L llm-ple -E lazy_itable_init=1,lazy_journal_init=1 -b 4096 ${device}

Grund fuer ext4 (und nicht ZFS/btrfs direkt darunter): der Vorleser der Runtime
nutzt io_uring; auf ZFS schlägt das mit 'Function not implemented (os error 38)' fehl,
und ein Copy-on-Write-Dateisystem wuerde die Leselatenz der Tabellenauszuege erhoehen.
MSG
  exit 1
fi

sudo install -d -m 0755 "${PLE_NATIVE_MOUNT}"
# mountpoint(1) also returns success for an automount placeholder.  That left
# Pennyroyal with an empty /ple tree after boot even though the zvol existed.
# Require the actual zvol as the top mount and repair a stale/placeholder mount.
mounted_source="$(findmnt -n -o SOURCE -T "${PLE_NATIVE_MOUNT}" 2>/dev/null || true)"
if [[ "${mounted_source}" != "${device}" ]]; then
  if [[ -n "${mounted_source}" ]]; then
    sudo umount "${PLE_NATIVE_MOUNT}" || sudo umount -l "${PLE_NATIVE_MOUNT}"
  fi
  sudo mount -o noatime,nodiratime "${device}" "${PLE_NATIVE_MOUNT}"
else
  # A previous manual repair can leave the same filesystem stacked twice.
  # Keep the fstab/systemd mount and avoid accumulating another layer.
  mount_options="$(findmnt -n -o OPTIONS -T "${PLE_NATIVE_MOUNT}" 2>/dev/null || true)"
  if [[ "${mount_options}" != *noatime* || "${mount_options}" != *nodiratime* ]]; then
    sudo mount -o remount,noatime,nodiratime "${PLE_NATIVE_MOUNT}"
  fi
fi
if [[ "$(stat -c %u "${PLE_NATIVE_MOUNT}")" != "$(id -u)" ]]; then
  sudo chown "$(id -u):$(id -g)" "${PLE_NATIVE_MOUNT}"
fi

# This mount is a hard prerequisite for the Pennyroyal user service.  An
# automount can remain a system-manager autofs placeholder while the user
# container starts, causing the runtime to see an empty /ple directory.
line="${device} ${PLE_NATIVE_MOUNT} ext4 noatime,nodiratime,nofail 0 2"
if ! grep -Fqx -- "${line}" /etc/fstab; then
  if grep -Fq -- "${PLE_NATIVE_MOUNT}" /etc/fstab; then
    echo "WARNUNG: /etc/fstab hat bereits einen anderen Eintrag fuer ${PLE_NATIVE_MOUNT}; bitte pruefen." >&2
  else
    printf '%s\n' "${line}" | sudo tee -a /etc/fstab >/dev/null
    log "fstab-Eintrag ergaenzt."
  fi
fi
systemctl --user daemon-reload 2>/dev/null || true
findmnt -T "${PLE_NATIVE_MOUNT}" -o TARGET,SOURCE,FSTYPE,OPTIONS
verify
log "Native PLE-Flaeche bereit: ${source_desc} -> ${PLE_NATIVE_MOUNT}"
printf '\nNaechster Schritt (kopiert die Tabelle und prueft sie):\n  ./scripts/49-migrate-ple.sh\n'
