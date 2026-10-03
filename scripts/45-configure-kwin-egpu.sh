#!/usr/bin/env bash
# Bildschirme und Compositor so einstellen, dass die Rechenkarte frei fuer das
# Sprachmodell bleibt - oder umgekehrt, wenn ein Monitor an der externen Karte
# haengt.
#
#   ./scripts/45-configure-kwin-egpu.sh --plan                 anzeigen (Standard)
#   ./scripts/45-configure-kwin-egpu.sh --modus llm            Desktop auf Intel,
#                                                              Blackwell nur fuer CUDA
#   ./scripts/45-configure-kwin-egpu.sh --modus egpu           Desktop auf Blackwell
#                                                              (Monitor haengt daran)
#   ./scripts/45-configure-kwin-egpu.sh --ruckgaengig          Datei entfernen
#
# Warum das ueberhaupt ein Skript ist: ohne Vorgabe nimmt KWin die schnellste
# Karte, und dann malen Firefox-Fenster und der Compositor auf derselben GPU, die
# das Modell braucht. Das kostet Speicher, Strom und Taktspitzen.
#
# Nach dem Schreiben ist eine neue Plasma-Sitzung noetig (abmelden, anmelden).
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${root}/lib/common.sh"
target_file=/etc/environment.d/90-llm-infra-drm.conf
mode=show
while [[ $# -gt 0 ]]; do
  case "$1" in
    --plan) mode=show; shift ;;
    --modus) mode="$2"; shift 2 ;;
    --ruckgaengig) mode=undo; shift ;;
    *) echo "unbekanntes Argument: $1 (hilfe: --plan, --modus llm|egpu, --ruckgaengig)" >&2; exit 2 ;;
  esac
done

# Karten zuordnen (numerisch wechseln die Gerate nach Neustart, deshalb ueber PCI)
intel_card=""
nvidia_card=""
for link in /dev/dri/by-path/pci-*; do
  [[ "${link}" == *-card ]] || continue
  bus="$(basename "${link}" | sed 's/^pci-//; s/-card$//')"
  # Der Treibername steht im Symlink-Namen des driver-Verzeichnisses.
  driver="$(basename "$(readlink -f "/sys/bus/pci/devices/${bus}/driver" 2>/dev/null || echo unbekannt)")"
  node="$(readlink -f "${link}")"
  case "${driver}" in
    i915|xe)        intel_card="${node}" ;;
    nvidia|nvidia-* ) nvidia_card="${node}" ;;
  esac
  log "Grafikkarte ${bus} (${driver:-unbekannt}) -> ${node}"
done

# Haengen Bildschirme an der externen Karte? Dann waere ein Umzug gefaehrlich.
connected_on_nvidia=0
if [[ -n "${nvidia_card}" ]]; then
  nvidia_base="$(basename "${nvidia_card}")"
  for status in /sys/class/drm/${nvidia_base}-*/status; do
    [[ -f "${status}" ]] || continue
    if [[ "$(cat "${status}")" == connected ]]; then
      echo "angeschlossener Bildschirm an der externen Karte: $(basename "$(dirname "${status}")")"
      connected_on_nvidia=1
    fi
  done
  if [[ "${connected_on_nvidia}" == 0 ]]; then
    echo 'keine angeschlossenen Bildschirme an der externen Karte'
  fi
fi

write_file() {
  local content="$1"
  if [[ "${mode}" == show ]]; then
    echo "Wuerde ${target_file} schreiben:"
    printf '%s\n' "${content}" | sed 's/^/    /'
    return 0
  fi
  sudo install -d -m 0755 /etc/environment.d
  printf '%s\n' "${content}" | sudo tee "${target_file}" >/dev/null
  echo "Geschrieben: ${target_file}"
  echo 'Abmelden und wieder anmelden, damit KWin die neue Reihenfolge sieht.'
}

case "${mode}" in
  show|plan)
    echo 'Entwurf (Standard: Intel fuehrt, Blackwell bleibt fuer CUDA frei):'
    [[ -n "${intel_card}" ]] && printf '    KWIN_DRM_DEVICES=%s:%s\n' "${intel_card}" "${nvidia_card:-}"
    echo
    echo 'Anwenden mit: ./scripts/45-configure-kwin-egpu.sh --modus llm'
    ;;
  llm)
    [[ -n "${intel_card}" ]] || { echo 'FEHLT: Intel-Karte nicht erkannt.' >&2; exit 1; }
    if (( connected_on_nvidia == 1 )); then
      cat >&2 <<MSG
ABBRUCH: Es haengt mindestens ein Bildschirm an der externen Karte.
Ein Umzug des Desktops auf die Intel-Grafik wuerde den Bildschirm abschalten.
Entweder den Bildschirm an einen Intel-Ausgang umstecken, oder bewusst mit
  KOPF_BETRIEB=1 ./scripts/45-configure-kwin-egpu.sh --modus llm
durchfuehren (nur fuer Betrieb ohne Bildschirm / Fernwartung).
MSG
      [[ "${KOPF_BETRIEB:-0}" == 1 ]] || exit 1
    fi
    write_file "KWIN_DRM_DEVICES=${intel_card}${nvidia_card:+:${nvidia_card}}
KWIN_DRM_ALLOW_DRM_LEASE=false
EGL_PLATFORM=surfaceless"
    ;;
  egpu)
    [[ -n "${nvidia_card}" ]] || { echo 'FEHLT: NVIDIA-Karte nicht erkannt.' >&2; exit 1; }
    write_file "KWIN_DRM_DEVICES=${nvidia_card}${intel_card:+:${intel_card}}"
    ;;
  undo)
    sudo rm -f "${target_file}"
    echo 'Entfernt. Nach dem naechsten Anmelden gilt wieder die automatische Wahl.'
    ;;
  *) echo "unknown modus: ${mode}" >&2; exit 2 ;;
esac
