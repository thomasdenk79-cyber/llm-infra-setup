#!/usr/bin/env bash
# Bringt Quadlet-Aenderungen aus dem Repo gefahrlos in den laufenden Betrieb.
#
#   ./scripts/apply-runtime-unit.sh                 diff zeigen und sicher anwenden
#   ./scripts/apply-runtime-unit.sh --dry-run       nur zeigen, nichts aendern
#   ./scripts/apply-runtime-unit.sh --list          drift ueber alle Units
#   ./scripts/apply-runtime-unit.sh --restart-only  Runtime neu starten (mit Schutz)
#
# Schutz: ein Neustart von Pennyroyal verwirft alle laufenden Anfragen und kostet
# ~15 Minuten Kaltstart. Deshalb wird abgebrochen, solange Anfragen laufen, wenn
# PENNYROYAL_PROTECT=1 gesetzt ist, oder ohne --force.
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${root}/lib/common.sh"
source "${root}/lib/units.sh"
[[ -f "${root}/config/host.env" ]] && source "${root}/config/host.env"
: "${PENNYROYAL_PORT:=8001}"
dry=0; mode=apply; force=0
for a in "$@"; do
  case "$a" in
    --dry-run) dry=1 ;;
    --list) mode=list ;;
    --restart-only) mode=restart ;;
    --force) force=1 ;;
    *) printf 'unbekanntes Argument: %s\n' "$a" >&2; exit 2 ;;
  esac
done

running_requests() {
  curl -fsS --max-time 5 "http://127.0.0.1:${PENNYROYAL_PORT}/metrics" 2>/dev/null \
    | awk '/^sglang:num_running_reqs\{/ {print $2; found=1} END{if(!found) print 0}'
}

require_idle_runtime() {
  local running
  if [[ "${PENNYROYAL_PROTECT:-0}" == 1 && "${force}" != 1 ]]; then
    echo 'ABGEBROCHEN: PENNYROYAL_PROTECT=1. Der Runtime-Neustart wurde bewusst gesperrt.' >&2
    echo 'Wenn du sicher bist: PENNYROYAL_PROTECT=0 ./scripts/apply-runtime-unit.sh --force' >&2
    return 1
  fi
  running="$(running_requests)"
  if [[ "${running%.*}" != 0 && "${force}" != 1 ]]; then
    echo "ABGEBROCHEN: es laufen gerade ${running} Anfragen. Warten oder --force." >&2
    return 1
  fi
  return 0
}

restart_runtime() {
  require_idle_runtime || return 1
  log 'Starte Pennyroyal neu (Kaltstart ~15 Minuten).'
  systemctl --user restart pennyroyal.service
  log 'Neustart ausgeloest. Fortschritt: journalctl --user -u pennyroyal.service -f'
  log 'Laufzeitpruefung danach: make healthcheck'
}

case "${mode}" in
  list)
    rc=0
    for unit in "${INFERENCE_UNITS[@]}" "${OBSERVABILITY_UNITS[@]}"; do
      [[ -f "${root}/quadlet/${unit}" ]] || continue
      if installed_unit_diff "${unit}" >/dev/null 2>&1; then
        printf 'GLEICH   %s\n' "${unit}"
      else
        printf 'ANDERS   %s\n' "${unit}"; rc=1
      fi
    done
    [[ "${rc}" == 0 ]] && printf 'Repo und Laeufer sind identisch.\n' \
      || printf 'Es gibt Abweichungen. Naechster Schritt: ./scripts/apply-runtime-unit.sh --dry-run\n'
    exit "${rc}"
    ;;
  restart)
    restart_runtime
    ;;
  apply)
    prune_legacy_units
    changed=0
    for unit in "${INFERENCE_UNITS[@]}" "${OBSERVABILITY_UNITS[@]}"; do
      [[ -f "${root}/quadlet/${unit}" ]] || continue
      if installed_unit_diff "${unit}" >/dev/null 2>&1; then
        printf 'GLEICH   %s\n' "${unit}"
        continue
      fi
      changed=1
      printf '\nANDERS   %s\n' "${unit}"
      installed_unit_diff "${unit}" || true
      if [[ "${dry}" == 1 ]]; then
        printf '   (--dry-run: nichts geaendert)\n'
        continue
      fi
      render_unit "${unit}"
    done
    if [[ "${dry}" == 1 ]]; then
      printf '\n--dry-run beendet. Anwenden mit: ./scripts/apply-runtime-unit.sh\n'
      exit 0
    fi
    if [[ "${changed}" == 1 ]]; then
      systemd_reload
      start_units "${INFERENCE_UNITS[@]}" "${OBSERVABILITY_UNITS[@]}"
      printf '\nHinweis: ein laufender Container uebernimmt eine neue Unit-Datei erst nach Neustart.\n'
      if installed_unit_diff pennyroyal.container >/dev/null 2>&1 && unit_is_active pennyroyal.container; then
        printf 'Pennyroyal-Unit ist jetzt identisch; der Laeufer laeuft aber noch mit der alten Konfiguration.\n'
        printf 'Wenn passend: ./scripts/apply-runtime-unit.sh --restart-only\n'
      fi
      printf '\nPruefen: make healthcheck und ./scripts/doctor.sh\n'
    else
      printf 'Nichts zu tun.\n'
    fi
    ;;
esac
