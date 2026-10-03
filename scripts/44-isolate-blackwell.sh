#!/usr/bin/env bash
# Die Anzeigeseite der Rechenkarte fuer das Modell freigeben.
#
#   ./scripts/44-isolate-blackwell.sh --plan            anzeigen (Standard)
#   ./scripts/44-isolate-blackwell.sh                  Regel schreiben und pruefen
#   ./scripts/44-isolate-blackwell.sh --ruckgaengig     Regel entfernen
#   ./scripts/44-isolate-blackwell.sh --zeige-nutzer    wer haelt gerade die Karte
#
# Was passiert: Die DRM-Knoten der NVIDIA-Karte (/dev/dri/card0, renderD129) werden
# per udev-Regel nur noch dem Betreiber mit Rechten 0660 zugeordnet, aber der
# Gruppe root. Programme, die sich einfach "die schnellste Karte" suchen - KWin,
# Firefox-Decodierung, Spiele, Screenshots - finden damit keinen Anzeigepfad mehr
# auf der Blackwell und nehmen die Intel-Grafik.
#
# Rechnet das Modell trotzdem weiter? Ja: CUDA spricht /dev/nvidia* an, nicht die
# DRM-Knoten. Das Skript prueft das nach dem Aktivieren mit einem eigenen
# Container-Lauf (cuda-basisimage, nvidia-smi -L) und faellt sonst selbst zurueck.
#
# Vorhandene Fenster muessen neu gestartet werden: wer den Knoten schon offen hat,
# behaelt ihn bis zum Neustart des Programms.
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${root}/lib/common.sh"
rule_file=/etc/udev/rules.d/99-llm-infra-nvidia-drm.rules
rule_line='KERNEL=="card*", SUBSYSTEM=="drm", DRIVERS=="nvidia", OWNER="root", GROUP="root", MODE="0600"
KERNEL=="renderD*", SUBSYSTEM=="drm", DRIVERS=="nvidia", OWNER="root", GROUP="root", MODE="0600"'

list_users() {
  echo 'Programme mit Zugang zu den NVIDIA-DRM-Knoten:'
  # pipefail beachten: lsof liefert nicht-null, wenn es nur einen Teil der Knoten
  # lesen kann. Deshalb zuerst in eine Variable, dann auswerten.
  local offen
  offen="$(sudo lsof /dev/dri/card0 /dev/dri/renderD129 2>/dev/null | awk 'NR>1 {print "  " $1, "pid", $2}' | sed 's/\\x20/ /g' | sort -u || true)"
  if [[ -n "${offen}" ]]; then
    printf '%s\n' "${offen}"
  else
    echo '  (niemand - die Anzeigeknoten sind frei)'
  fi
  echo
  echo 'Rechenauftraege auf der Karte (CUDA):'
  local apps
  apps="$(nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader 2>/dev/null || true)"
  if [[ -n "${apps}" ]]; then
    printf '%s\n' "${apps}" | sed 's/^/  /'
  else
    echo '  keine'
  fi
}

mode=show
while [[ $# -gt 0 ]]; do
  case "$1" in
    --plan) mode=show; shift ;;
    --ruckgaengig) mode=undo; shift ;;
    --zeige-nutzer) list_users; exit 0 ;;
    *) echo 'unbekanntes Argument (hilfe: --plan, --ruckgaengig, --zeige-nutzer)' >&2; exit 2 ;;
  esac
done

if [[ "${mode}" == undo ]]; then
  sudo rm -f "${rule_file}"
  sudo udevadm control --reload-rules
  sudo udevadm trigger --subsystem-match=drm
  echo 'Regel entfernt; Anzeigeprogramme duerfen die Karte wieder benutzen.'
  exit 0
fi

if [[ "${mode}" == show ]]; then
  echo "Wuerde ${rule_file} schreiben:"
  printf '%s\n' "${rule_line}" | sed 's/^/    /'
  list_users
  echo
  echo 'Anwenden mit: ./scripts/44-isolate-blackwell.sh   (danach Browser/Plasma neu starten)'
  exit 0
fi

printf '%s\n' "${rule_line}" | sudo tee "${rule_file}" >/dev/null
log 'udev-Regel geschrieben, aktiviere sie ...'
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=drm
sleep 2
ls -l /dev/dri/card0 /dev/dri/renderD129 2>/dev/null | sed 's/^/  /' || true

if ! command -v podman >/dev/null 2>&1; then
  echo 'podman fehlt - CUDA-Test kann nicht laufen. Regel bleibt, zurueck: --ruckgaengig' >&2
  exit 1
fi
image='docker.io/nvidia/cuda:12.8.1-base-ubuntu24.04'
if ! podman image exists "${image}"; then
  retry podman pull "${image}" || { echo 'Testimage nicht ladbar; CUDA-Test uebersprungen.' >&2; exit 1; }
fi
echo 'Pruefe, ob CUDA die Karte weiterhin sieht ...'
if retry podman run --rm --device nvidia.com/gpu=all "${image}" nvidia-smi -L; then
  echo 'OK: Rechenpfad frei, Anzeigepfad gesperrt.'
  echo 'Noetig zum Nachziehen: Browser und Plasma neu starten (alte Fenster behalten den alten Knoten).'
  list_users
else
  echo 'CUDA sieht die Karte nicht mehr - das war nicht das Ziel. Ich nehme die Regel zurueck.' >&2
  sudo rm -f "${rule_file}"
  sudo udevadm control --reload-rules
  sudo udevadm trigger --subsystem-match=drm
  exit 1
fi
