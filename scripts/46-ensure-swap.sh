#!/usr/bin/env bash
# Stellt die zweite Ausweichstufe der Auslagerung sicher: /swap/swapfile mit
# fester Groesse (Standard 32G) auf der NVMe, ordnungsgemaess anonymisiert
# angelegt (nocow auf btrfs) und in /etc/fstab verankert.
#
# Warum ueberhaupt Platten-Swap neben zram: zram komprimiert in den RAM und
# ist die schnelle erste Stufe (Prio 100). Wenn die voll laeuft, muss eine
# echte zweite Stufe dahinterstehen, die kalte Seiten auf die NVMe legt -
# sonst steht der Rechner bei Speicherdruck still. Bewusst NICHT gleichrangig:
# heisse Seiten bleiben in der Komprimierung, nur der Ueberlauf kommt auf
# Platte. Deshalb bleibt die niedrige Prio des Dateitauschs.
#
#   ./scripts/46-ensure-swap.sh              einrichten bzw. auf Groesse bringen
#   ./scripts/46-ensure-swap.sh --check      nur pruefen (Exit 1 bei Abweichung)
#   SWAP_DATEI=/pfad SWAP_GIGS=48            eigene Grosse/Pfad (Betreiber)
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/common.sh
source "${root}/lib/common.sh"

: "${SWAP_DATEI:=/swap/swapfile}"
: "${SWAP_GIGS:=32}"
: "${SWAP_PRIO:=10}"

check_only=0
[[ "${1:-}" == "--check" ]] && check_only=1

# aktiver Bestand
ist_gib=0
aktiv=0
swp="$(swapon -s 2>/dev/null | awk -v f="${SWAP_DATEI}" '$1==f {print $3}')"
if [[ -n "${swp:-}" ]]; then
  aktiv=1
  # diese swapon-Fassung meldet die Groesse in KiB
  ist_gib=$(( (swp + 1048575) / 1048576 ))  # Kopfseite abgezinst, also aufrunden
fi

soll_bytes=$(( SWAP_GIGS * 1024 * 1024 * 1024 ))

if (( aktiv == 1 )) && (( ist_gib >= SWAP_GIGS )); then
  log "Ausweichstufe steht: ${SWAP_DATEI} mit ${ist_gib} GiB aktiv."
  exit 0
fi

if (( check_only == 1 )); then
  die "${SWAP_DATEI} fehlt oder ist kleiner als ${SWAP_GIGS} GiB (ist: ${ist_gib} GiB, aktiv: ${aktiv}). Naechster Schritt: ./scripts/46-ensure-swap.sh   (legt an bzw. vergroessert, braucht sudo)"
fi

log "Richte Ausweichstufe ein: ${SWAP_DATEI} auf ${SWAP_GIGS} GiB (Prio ${SWAP_PRIO})."

# sudo-Pfad: alle Privilegschritte einzeln, damit die Ausgabe lesbar bleibt
runpriv() {
  if [[ "${EUID}" -eq 0 ]]; then bash -c "$*"; else sudo -n bash -c "$*"; fi
}

if [[ ! -e "${SWAP_DATEI}" ]]; then
  runpriv "install -d -m 0700 \"$(dirname "${SWAP_DATEI}")\""
  # btrfs verlangt NOCOW+nodatasum fuer Tauschdateien; ext4 schadet es nicht
  runpriv "fallocate -l ${soll_bytes} \"${SWAP_DATEI}\" || dd if=/dev/zero of=\"${SWAP_DATEI}\" bs=1M count=$(( SWAP_GIGS * 1024 )) status=none"
  runpriv "chattr +C \"${SWAP_DATEI}\" 2>/dev/null || true"
  runpriv "chmod 0600 \"${SWAP_DATEI}\""
  runpriv "mkswap -L llm-swap \"${SWAP_DATEI}\" >/dev/null"
  runpriv "swapon -p ${SWAP_PRIO} \"${SWAP_DATEI}\""
else
  # vorhanden, aber zu klein: groesser machen (kurzer Tausch-Aussetz)
  runpriv "swapoff \"${SWAP_DATEI}\""
  # truncate haette den Anhang nur als Locher angelegt - der Kernel
  # verwirft so eine Datei; also den neuen Bereich mit Nullen fuellen.
  runpriv "alt_mib=\$(( $(stat -c%s \"${SWAP_DATEI}\") / 1048576 )); truncate -s ${soll_bytes} \"${SWAP_DATEI}\"; dd if=/dev/zero of=\"${SWAP_DATEI}\" bs=1M seek=\$(( alt_mib - 1 )) count=\$(( ${SWAP_GIGS} * 1024 - alt_mib + 1 )) conv=notrunc status=none"
  runpriv "mkswap -f -L llm-swap \"${SWAP_DATEI}\" >/dev/null"
  runpriv "swapon -p ${SWAP_PRIO} \"${SWAP_DATEI}\""
fi

# fstab-Eintrag nur anlegen, wenn kein anderer Eintrag fuer diese Datei spricht
if ! grep -qs "^${SWAP_DATEI}[[:space:]]" /etc/fstab; then
  runpriv "printf '%s none swap defaults,pri=${SWAP_PRIO} 0 0\n' '${SWAP_DATEI}' >> /etc/fstab"
  log "fstab-Eintrag ergaenzt."
fi

aktiv_now=0
[[ "$(findmnt -rn -o FSTYPE -T "${SWAP_DATEI}" 2>/dev/null)" != "" ]] && aktiv_now=1
if swapon -s 2>/dev/null | awk '{print $1}' | grep -qx "${SWAP_DATEI}"; then
  log "Ausweichstufe aktiv: $(( $(swapon -s 2>/dev/null | awk -v f="${SWAP_DATEI}" '$1==f {print $3}') / 1048576 )) GiB"
else
  die "Datei steht, ist aber nicht aktiv. Naechster Schritt: swapon -p ${SWAP_PRIO} ${SWAP_DATEI}   (Fehlergrund: journalctl -k | tail)"
fi
log "Naechster Schritt: ./scripts/46-ensure-swap.sh --check"
