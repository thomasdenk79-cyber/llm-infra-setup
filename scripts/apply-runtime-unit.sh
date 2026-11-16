#!/usr/bin/env bash
# Bringt Quadlet-Aenderungen aus dem Repo gefahrlos in den laufenden Betrieb.
#
#   ./scripts/apply-runtime-unit.sh                 diff zeigen und sicher anwenden
#   ./scripts/apply-runtime-unit.sh --dry-run       nur zeigen, nichts aendern
#   ./scripts/apply-runtime-unit.sh --list          drift ueber alle Units
#   ./scripts/apply-runtime-unit.sh --restart-only  Runtime neu starten (mit Schutz)
#   ./scripts/apply-runtime-unit.sh --install-only  Units installieren, nichts starten
#   ./scripts/apply-runtime-unit.sh --takeover      von Hand gestarteten Container uebernehmen
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
    --takeover) mode=takeover ;;
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
  laufzeit_bestimmen
  require_idle_runtime || return 1
  log "Starte ${laufzeit_unit}.service neu (Kaltstart ~15 Minuten)."
  systemctl --user restart "${laufzeit_unit}.service"
  log "Neustart ausgeloest. Fortschritt: journalctl --user -u ${laufzeit_unit}.service -f"
  log 'Laufzeitpruefung danach: make healthcheck'
}

laufzeit_bestimmen() {
  # RUNTIME_UNIT kann leer sein (So war es auf diesem Rechner bisher). Dann wird die
  # Unit ueber den ContainerNamen gesucht, den sie beschreibt - geraten wird nicht:
  # ohne passenden Treffer bleibt es bei der Angabe aus host.env.
  [[ -n "${RUNTIME_UNIT:-}" ]] && return 0
  local datei
  for datei in "${root}"/quadlet/*.container; do
    [[ -f "${datei}" ]] || continue
    if grep -qs "^ContainerName=${RUNTIME_CONTAINER:-__keiner__}\$" "${datei}"; then
      laufzeit_unit="$(basename "${datei}" .container)"
      log "Laufzeit-Unit am ContainerNamen erkannt: ${laufzeit_unit} (RUNTIME_UNIT war leer)."
      return 0
    fi
  done
  return 0
}

quadlet_schluessel() {
  # Liest einen Schluessel aus der Quadlet-Datei der Laufzeit (erste Zeile zaehlt).
  awk -F= -v schluessel="$1" '$1 == schluessel {print substr($0, index($0, "=") + 1); exit}' \
    "${root}/quadlet/${laufzeit_unit}.container"
}

spec_stimmt_mit_laeufer() {
  # Vergleicht die laufende Laufzeit mit der Spec, aus der die Unit gebaut ist. Ein
  # Neustart darf nicht in einer anderen Konfiguration enden als der, die gerade
  # Antworten liefert: sonst heisst 'laeuft wieder' nur 'laeuft anders'.
  local spec="${root}/config/runtime/${laufzeit_unit}.spec" container="${RUNTIME_CONTAINER:-}"
  [[ -f "${spec}" ]] || { echo "Spec fehlt: ${spec}" >&2; return 1; }
  [[ -n "${container}" ]] || { echo 'RUNTIME_CONTAINER ist nicht gesetzt (config/host.env).' >&2; return 1; }
  podman inspect "${container}" >/dev/null 2>&1 || { echo "Container ${container} existiert nicht." >&2; return 1; }

  local bild_unit bild_laeufer
  bild_unit="$(sed -n 's/^IMAGE=//p' "${spec}" | head -1)"
  bild_laeufer="$(podman inspect "${container}" --format '{{.Config.Image}}')"
  if [[ "${bild_unit}" != "${bild_laeufer}" ]]; then
    echo "Bildunterschied: Unit ${bild_unit}, Laeufer ${bild_laeufer}." >&2
    return 1
  fi

  local anzahl_spec anzahl_laeufer
  anzahl_spec="$(grep -c '^EXEC_ARG=' "${spec}")"
  anzahl_laeufer="$(podman inspect "${container}" --format '{{len .Config.Cmd}}')"
  if [[ "${anzahl_spec}" != "${anzahl_laeufer}" ]]; then
    echo "Schalteranzahl unterschiedlich: Spec ${anzahl_spec}, Laeufer ${anzahl_laeufer}." >&2
    echo "  Naechster Befehl: ./scripts/76-setup-runtime-unit.sh --import-from-container ${container}" >&2
    return 1
  fi
  return 0
}

uebernahme() {
  # Uebernimmt einen von Hand gestarteten Container in die Unit. Ohne Rueckweg und
  # ohne Uebereinstimmung von Spec und Laeufer wird abgebrochen.
  laufzeit_bestimmen
  require_idle_runtime || return 1
  local container rueckweg
  container="$(quadlet_schluessel ContainerName)"
  [[ -n "${container}" ]] || die "quadlet/${laufzeit_unit}.container nennt keinen ContainerName."
  rueckweg="${root}/state/runtime-restore-${container}.sh"
  [[ -x "${rueckweg}" ]] || die "Kein Rueckweg unter ${rueckweg}. Vor der Uebernahme aufnehmen: ./scripts/76-setup-runtime-unit.sh --import-from-container ${container}"
  spec_stimmt_mit_laeufer || die "Laufende Laufzeit unterscheidet sich von der Spec - zuerst neu aufnehmen (Ausgabe oben)."

  if unit_is_active "${laufzeit_unit}.container" && podman ps --format '{{.Names}}' | grep -qx "${container}"; then
    log "${laufzeit_unit}.service besitzt ${container} bereits - nichts zu uebernehmen."
    return 0
  fi

  log "Uebernahme: ${container} kommt unter die Verwaltung von ${laufzeit_unit}.service."
  log "Rueckweg, falls die Unit sich nicht bewaehrt: ${rueckweg}"
  if podman ps -a --format '{{.Names}}' | grep -qx "${container}"; then
    log 'Container wird angehalten und entfernt; Bild, Modell und Cache bleiben erhalten.'
    podman stop --time 60 "${container}" >/dev/null
    podman rm "${container}" >/dev/null
  fi
  systemctl --user restart "${laufzeit_unit}.service"
  # host.env ist die kanonische Ansprache fuer Pruefskripte: RUNTIME_UNIT erst dann,
  # wenn die Unit den Container wirklich besitzt - sonst meldet der Arztlauf eine
  # Unit als Laufzeit, die an der laufenden Konfiguration vorbeilaeuft.
  if [[ -f "${root}/config/host.env" ]] && ! grep -qs "^RUNTIME_UNIT=${laufzeit_unit}\$" "${root}/config/host.env"; then
    sed -i "s/^RUNTIME_UNIT=.*/RUNTIME_UNIT=${laufzeit_unit}/" "${root}/config/host.env"
    log "config/host.env: RUNTIME_UNIT=${laufzeit_unit} eingetragen."
  fi
  log "Neustart ausgeloest. Fortschritt: journalctl --user -u ${laufzeit_unit}.service -f"
  log 'Danach: make healthcheck   (Kaltstart ~15 Minuten)'
}

case "${mode}" in
  takeover)
    uebernahme
    ;;
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
    # Die nächste Hilfe-Zeile am Ende nennt eine Unit - die darf nicht geraten sein.
    laufzeit_bestimmen
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
