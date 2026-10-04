#!/usr/bin/env bash
# Wiederholt Matrixläufe und lässt Fehler parallel durch Luna reparieren.
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cycles="${PLE_MATRIX_MAX_CYCLES:-0}"
run_root="$root/state/variant-runs"
log(){ printf '[%s] %s\n' "$(date --iso-8601=seconds)" "$*"; }
for ((cycle=1; cycles == 0 || cycle <= cycles; cycle++)); do
  log "Matrixrunde $cycle startet."
  cycle_start_epoch="$(date +%s)"
  while systemctl --user is-active --quiet ple-variant-matrix.service; do
    log 'Vorheriger Matrixlauf läuft noch; Supervisor wartet.'
    sleep 30
  done
  while systemctl --user is-active --quiet ple-research-audit.service; do
    log 'Forschungsprüfung läuft noch; Supervisor startet keine neue GPU-Variante.'
    sleep 30
  done
  systemd-run --user --unit=ple-variant-matrix --collect --property=Type=exec \
    "$root/scripts/run-ple-variant-matrix.sh" --retry-failed
  # Race: systemd-run kehrt nach der Jobabgabe zurueck; die Unit kann noch
  # registriert werden. Erst auf Registrierung warten, sonst werte ein sofort
  # beendeter Lauf als "nicht laufend" und die alte summary.csv waere neu.
  registered=0
  for _ in $(seq 1 24); do
    state="$(systemctl --user show -p ActiveState --value ple-variant-matrix.service 2>/dev/null || echo inactive)"
    case "$state" in
      activating|active|reloading|deactivating) registered=1; break ;;
    esac
    sleep 5
  done
  if (( registered == 1 )); then
    while systemctl --user is-active --quiet ple-variant-matrix.service; do sleep 20; done
  else
    log 'Matrix-Unit wurde nicht als laufend beobachtet; Pruefung, ob ein neues Laufverzeichnis entstand.'
  fi
  run_dir="$(find "$run_root" -mindepth 1 -maxdepth 1 -type d -newermt "@${cycle_start_epoch}" -printf '%T@ %p\n' 2>/dev/null \
    | sort -nr | head -1 | cut -d' ' -f2-)"
  failed=0
  jobs=()
  if [[ -z "$run_dir" || ! -f "$run_dir/summary.csv" ]]; then
    log 'Kein neues Laufverzeichnis mit summary.csv gefunden; Rundezaehlt als Fehler, alte Laeufe werden nicht geheilt.'
    failed=1
  else
    while IFS=, read -r variant result _detail; do
      [[ "$variant" == variant ]] && continue
      case "$result" in
        passed) ;;
        *)
          failed=1
          if [[ ! -e "$run_dir/healing/$variant.done" ]]; then
            "$root/scripts/ple-heal-failure.sh" "$variant" "$run_dir" & jobs+=("$!")
          fi
          ;;
      esac
    done < "$run_dir/summary.csv"
  fi
  for job in "${jobs[@]:-}"; do wait "$job" || true; done
  research_pid=""
  if [[ "${PLE_RESEARCH_AUDIT:-1}" == 1 ]]; then
    "$root/scripts/ple-research-audit.sh" & research_pid="$!"
    log "Parallele Qwen-Forschungsprüfung aller Varianten gestartet (PID $research_pid)."
  fi
  if [[ -n "$research_pid" ]]; then wait "$research_pid" || true; fi
  if [[ "${PLE_MATRIX_HEALER:-1}" == 1 ]]; then
    log 'Qwen-Matrix-Heiler prüft Runner, Benchmark und Umgebung.'
    "$root/scripts/ple-matrix-healer.sh" || true
  fi
  (( failed == 0 )) && { log 'Alle Varianten erfolgreich; Supervisor beendet.'; exit 0; }
  log 'Fehler repariert oder dokumentiert; nächste Matrixrunde folgt.'
done
log "Maximale Matrixrunden erreicht: $cycles"
exit 1
