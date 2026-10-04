#!/usr/bin/env bash
# Wiederholt Matrixläufe und lässt Fehler parallel durch Luna reparieren.
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cycles="${PLE_MATRIX_MAX_CYCLES:-0}"
run_root="$root/state/variant-runs"
log(){ printf '[%s] %s\n' "$(date --iso-8601=seconds)" "$*"; }
for ((cycle=1; cycles == 0 || cycle <= cycles; cycle++)); do
  log "Matrixrunde $cycle startet."
  while systemctl --user is-active --quiet ple-variant-matrix.service; do
    log 'Vorheriger Matrixlauf läuft noch; Supervisor wartet.'
    sleep 30
  done
  systemd-run --user --unit=ple-variant-matrix --collect --property=Type=exec \
    "$root/scripts/run-ple-variant-matrix.sh" --retry-failed
  while systemctl --user is-active --quiet ple-variant-matrix.service; do sleep 20; done
  run_dir="$(find "$run_root" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' \
    | sort -nr | head -1 | cut -d' ' -f2-)"
  failed=0
  jobs=()
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
  for job in "${jobs[@]:-}"; do wait "$job" || true; done
  (( failed == 0 )) && { log 'Alle Varianten erfolgreich; Supervisor beendet.'; exit 0; }
  log 'Fehler repariert oder dokumentiert; nächste Matrixrunde folgt.'
done
log "Maximale Matrixrunden erreicht: $cycles"
exit 1
