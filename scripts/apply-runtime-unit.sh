#!/usr/bin/env bash
# Bringt Quadlet-Aenderungen aus dem Repo gefahrlos in den laufenden Betrieb.
#
#   ./scripts/apply-runtime-unit.sh                 diff zeigen und sicher anwenden
#   ./scripts/apply-runtime-unit.sh --dry-run       nur zeigen, nichts aendern
#   ./scripts/apply-runtime-unit.sh --list          drift ueber alle Units
#   ./scripts/apply-runtime-unit.sh --restart-only  Runtime neu starten (mit Schutz)
#   ./scripts/apply-runtime-unit.sh --install-only  Units installieren, nichts starten
#
# Schutz: ein Neustart von Pennyroyal verwirft alle laufenden Anfragen und kostet
# ~15 Minuten Kaltstart. Deshalb wird abgebrochen, solange Anfragen laufen, wenn
# PENNYROYAL_PROTECT=1 gesetzt ist, oder ohne --force.
#
# Die Anzahl laufender Anfragen kommt vom Weiterleiter (vLLM) oder vom Gateway
# (sglang). Liefert keiner von beiden eine Zahl, wird abgebrochen: ein Neustart ins
# Blaue war bisher moeglich, weil der Blick auf einen Port ins Leere lief und 0
# ergab - das ist kein Leerlauf, sondern eine fehlende Aussage.
#
# --install-only ist fuer Units, die einen bereits laufenden Container beschreiben:
# starten wuerde mit 'name in use' scheitern, installiert sein soll die Unit trotzdem.
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${root}/lib/common.sh"
source "${root}/lib/units.sh"
[[ -f "${root}/config/host.env" ]] && source "${root}/config/host.env"
: "${PENNYROYAL_PORT:=8001}"
dry=0; mode=apply; force=0; start=1
for a in "$@"; do
  case "$a" in
    --dry-run) dry=1 ;;
    --list) mode=list ;;
    --restart-only) mode=restart ;;
    --install-only) start=0 ;;
    --force) force=1 ;;
    *) printf 'unbekanntes Argument: %s\n' "$a" >&2; exit 2 ;;
  esac
done

# Die Laufzeit dieses Rechners ist nicht Pennyroyal, sondern der Container aus
# config/host.env (RUNTIME_UNIT). Beides wird unterstuetzt: ohne Angabe bleibt der
# altbekannte Pennyroyal-Pfad gelten.
laufzeit_unit="${RUNTIME_UNIT:-pennyroyal}"
weiterleiter_port="${VLLM_METRICS_PORT:-30001}"

running_requests() {
  local ort mess wert
  for ort in "http://127.0.0.1:${weiterleiter_port}/metrics" "http://127.0.0.1:${PENNYROYAL_PORT}/metrics"; do
    mess="$(curl -fsS --max-time 5 "${ort}" 2>/dev/null)" || continue
    wert="$(printf '%s\n' "${mess}" \
      | awk '/^vllm:num_requests_running\{/ {print $2; gefunden=1; exit}
              /^sglang:num_running_reqs\{/ {print $2; gefunden=1; exit}
              END { if (!gefunden) print "unbekannt" }')"
    [[ "${wert}" == 'unbekannt' ]] && continue
    printf '%s\n' "${wert}"
    return 0
  done
  printf 'unbekannt\n'
}

require_idle_runtime() {
  local running
  if [[ "${PENNYROYAL_PROTECT:-0}" == 1 && "${force}" != 1 ]]; then
    echo 'ABGEBROCHEN: PENNYROYAL_PROTECT=1. Der Runtime-Neustart wurde bewusst gesperrt.' >&2
    echo 'Wenn du sicher bist: PENNYROYAL_PROTECT=0 ./scripts/apply-runtime-unit.sh --force' >&2
    return 1
  fi
  running="$(running_requests)"
  if [[ "${running}" == 'unbekannt' && "${force}" != 1 ]]; then
    echo 'ABGEBROCHEN: weder der Weiterleiter noch das Gateway nennt eine Zahl laufender Anfragen.' >&2
    echo "  Nachsehen: curl -s http://127.0.0.1:${weiterleiter_port}/metrics | head" >&2
    echo '  Bewusste Ausnahme (auf eigenes Risiko): ./scripts/apply-runtime-unit.sh --restart-only --force' >&2
    return 1
  fi
  if [[ "${running%.*}" != 0 && "${force}" != 1 ]]; then
    echo "ABGEBROCHEN: es laufen gerade ${running} Anfragen. Warten oder --force." >&2
    return 1
  fi
  return 0
}

restart_runtime() {
  require_idle_runtime || return 1
  log "Starte ${laufzeit_unit}.service neu (Kaltstart ~15 Minuten)."
  systemctl --user restart "${laufzeit_unit}.service"
  log "Neustart ausgeloest. Fortschritt: journalctl --user -u ${laufzeit_unit}.service -f"
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
      if [[ "${start}" == 1 ]]; then
        start_units "${INFERENCE_UNITS[@]}" "${OBSERVABILITY_UNITS[@]}"
      else
        printf '\nUnits installiert, nichts gestartet (--install-only).\n'
        printf 'Starten, wenn passend: systemctl --user start %s.service\n' "${laufzeit_unit}"
      fi
      printf '\nHinweis: ein laufender Container uebernimmt eine neue Unit-Datei erst nach Neustart.\n'
      if installed_unit_diff "${laufzeit_unit}.container" >/dev/null 2>&1 && unit_is_active "${laufzeit_unit}.container"; then
        printf '%s-Unit ist jetzt identisch; der Laeufer laeuft aber noch mit der alten Konfiguration.\n' "${laufzeit_unit}"
        printf 'Wenn passend: ./scripts/apply-runtime-unit.sh --restart-only\n'
      fi
      printf '\nPruefen: make healthcheck und ./scripts/doctor.sh\n'
    else
      printf 'Nichts zu tun.\n'
    fi
    ;;
esac
