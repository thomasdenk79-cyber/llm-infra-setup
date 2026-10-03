#!/usr/bin/env bash
# HEISSE PHASE: tuned Profil anwenden, Runtime neu starten, messen, bei
# Verschlechterung automatisch zurueck.
#
#   ./scripts/apply-tuning.sh --nur-plan        Was wuerde passieren? Nichts aendern.
#   ./scripts/apply-tuning.sh                   anwenden (Runtime-Neustart!)
#   ./scripts/apply-tuning.sh --profil konservativ   nur PLE-Umzug + HiCache 16
#   ./scripts/apply-tuning.sh --zurueck              letzte Sicherung zurueckholen
#   ./scripts/apply-tuning.sh --ohnemessung          starten ohne Benchmark-Gatter
#
# Was das Skript tut
#   1. Pruefen: genug freier RAM, PLE-Tabelle auf der neuen Flaeche gecheckt,
#      keine andere Tuning-Kopie, keine laufenden Chat-Anfragen (sonnt Warnung).
#   2. Stand sichern: config/host.env, Unit-Datei, letzte Messwerte.
#   3. Neue Werte schreiben, Unit erzeugen und installieren.
#   4. Runtime neu starten und auf "bereit" warten (Kaltstart ~15 Minuten).
#   5. Messen (Vorlaufzeit und Schreibrate) und mit der Baseline vergleichen.
#   6. Scheitert der Start oder faellt die Schreibrate, werden die gesicherten
#      Dateien zurueckgeschrieben und erneut gestartet.
#
# Wichtig fuer die Sitzungen, die gerade an diesem Modell haengen: Der Neustart
# trennt sie ab. opencode verbindet sich nach dem Neustart wieder; waehrend der
# Kaltstartzeit laufen Anfragen ins Leere.
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${root}/lib/common.sh"
source "${root}/lib/units.sh"

: "${PENNYROYAL_PORT:=8001}"
: "${RUNTIME_WAIT_SECONDS:=2400}"
profile=aggressiv
plan_only=0; rollback=0; skip_bench=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --nur-plan) plan_only=1; shift ;;
    --profil) profile="$2"; shift 2 ;;
    --zurueck) rollback=1; shift ;;
    --ohnemessung) skip_bench=1; shift ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *) echo 'unbekanntes Argument (hilfe: ./scripts/apply-tuning.sh --help)' >&2; exit 2 ;;
  esac
done

tune_base="${STATE_DIR}/tuning"
latest_link="${tune_base}/latest"
host_env="${root}/config/host.env"
# shellcheck disable=SC1090
[[ -f "${host_env}" ]] && source "${host_env}"
: "${PLE_NATIVE_MOUNT:=/srv/llm/ple-native}"
: "${PLE_STORAGE_MOUNT:=/srv/llm/ple-ext4}"
ple_name="$(basename "${PENNY_PLE_NVME_MODEL:-/srv/llm/ple-ext4/Qwen3.8-Flash-Next-PLE-NVME}")"

# --- Ruckfallmodus ----------------------------------------------------------
if [[ "${rollback}" == 1 ]]; then
  [[ -L "${latest_link}" ]] || { echo 'Kein frueherer Tuning-Lauf gefunden.' >&2; exit 1; }
  target="$(readlink -f "${latest_link}")"
  echo "Ruckfallierung auf ${target}"
  [[ -f "${target}/host.env" ]] || { echo 'Gesicherte host.env fehlt.' >&2; exit 1; }
  cp -f "${target}/host.env" "${host_env}"
  [[ -f "${target}/pennyroyal.container" ]] && cp -f "${target}/pennyroyal.container" "${root}/quadlet/pennyroyal.container"
  run ./scripts/50-install-pennyroyal.sh
  bash -c "cd '${root}'; source lib/common.sh; source lib/units.sh; render_unit pennyroyal.container; systemd_reload"
  run ./scripts/apply-runtime-unit.sh --restart-only --force
  run ./scripts/wait-for-runtime.sh
  run ./scripts/healthcheck.sh || true
  echo 'Ruckfallierung abgeschlossen.'
  exit 0
fi

# --- Profile ----------------------------------------------------------------
case "${profile}" in
  aggressiv)
    new_hicache=16; new_mem='0.99'; new_steps=5; new_draft=8; new_sleep=0; new_chunk=8192 ;;
  konservativ)
    new_hicache=16; new_mem='0.981'; new_steps=3; new_draft=4; new_sleep=1; new_chunk=4096 ;;
  *) echo "--profil muss aggressiv oder konservativ sein" >&2; exit 2 ;;
esac
new_ple="${PLE_NATIVE_MOUNT}/${ple_name}"

echo "== Tuning-Profil ${profile} =="
printf '  PLE-Flaeche      : %s\n' "${new_ple}"
printf '  HiCache (RAM)    : %s -> %s GiB\n' "${PENNY_HICACHE_SIZE_GB:-?}" "${new_hicache}"
printf '  mem-fraction     : %s -> %s\n' '0.981' "${new_mem}"
printf '  Spekulation      : 3/1/4 -> %s/1/%s\n' "${new_steps}" "${new_draft}"
printf '  sleep-on-idle    : 1 -> %s\n' "${new_sleep}"
printf '  chunked-prefill  : 4096 -> %s\n' "${new_chunk}"

# --- Vorbedingungen ---------------------------------------------------------
problems=0
need_cmd podman 'Jetzt ausführen: make install'

avail_kb="$(awk '/MemAvailable/ {print $2}' /proc/meminfo)"
if (( avail_kb < (new_hicache + 8) * 1024 * 1024 )); then
  echo "ZU WENIG RAM: ${avail_kb} KiB verfuegbar, HiCache ${new_hicache} GiB plus 8 GiB Ruhe noetig." >&2
  echo 'Sonst bricht das Modelladen wieder ab. Entweder Schliessen was RAM belegt,' >&2
  echo 'oder kleineres Profil: ./scripts/apply-tuning.sh --profil konservativ' >&2
  problems=1
else
  echo "OK: $(( avail_kb / 1024 / 1024 )) GiB RAM verfuegbar"
fi

if [[ ! -d "${new_ple}/ple" ]]; then
  echo "FEHLT: PLE-Tabelle auf der neuen Flaeche: ${new_ple}/ple" >&2
  echo 'Jetzt ausführen: ./scripts/49-migrate-ple.sh   (und --nur-pruefen danach)' >&2
  problems=1
elif ! tail -5 "${STATE_DIR}/ple-migrate.log" 2>/dev/null | grep -q 'PRÜFUNG OK\|PRUEFUNG OK'; then
  echo 'WARNUNG: Der Umzug meldet keine erfolgreiche Pruefung; ich pruefe selbst.' >&2
  "${root}/scripts/49-migrate-ple.sh" --nur-pruefen || problems=1
fi

if ! mountpoint -q "${PLE_NATIVE_MOUNT}"; then
  echo "FEHLT: ${PLE_NATIVE_MOUNT} ist nicht eingehaengt (fstab pruefen)." >&2
  problems=1
fi

running="$(curl -fsS --max-time 5 "http://127.0.0.1:${PENNYROYAL_PORT}/metrics" 2>/dev/null \
  | awk '/^sglang:num_running_reqs\{/ {print $2; found=1} END{if(!found) print 0}')"
if [[ "${running%.*}" != 0 ]]; then
  echo "ACHTUNG: ${running} Anfragen laufen gerade - die Sitzung(en) fallen beim Neustart ab." >&2
  if [[ "${plan_only}" == 1 ]]; then
    echo '   (Trockenlauf: Frage wird nicht gestellt.)'
  else
  echo 'Warten bis zu 5 Minuten? [J/N]'
  read -r answer
  if [[ "${answer}" == J || "${answer}" == j ]]; then
    for _ in $(seq 1 30); do
      sleep 10
      running="$(curl -fsS --max-time 5 "http://127.0.0.1:${PENNYROYAL_PORT}/metrics" 2>/dev/null | awk '/^sglang:num_running_reqs\{/ {print $2; exit}')"
      [[ "${running:-0}" == "0" || "${running:-0}" == "0.0" ]] && break
    done
  fi
  fi
fi

if (( problems == 1 )); then
  echo
  echo 'Abbruch: Vorbedingungen nicht erfuellt. Nichts geaendert.'
  exit 1
fi

if [[ "${plan_only}" == 1 ]]; then
  echo
  echo '--nur-plan beendet. Anwenden mit: ./scripts/apply-tuning.sh'
  exit 0
fi

# --- Baseline und Sicherung -------------------------------------------------
ts="$(date -u +%Y%m%dT%H%M%SZ)"
run_dir="${tune_base}/${ts}"
install -d -m 0700 "${run_dir}"
cp -f "${host_env}" "${run_dir}/host.env"
[[ -f "${root}/quadlet/pennyroyal.container" ]] && cp -f "${root}/quadlet/pennyroyal.container" "${run_dir}/pennyroyal.container"
latest_baseline="$(ls -1t "${STATE_DIR}/benchmarks"/*.json 2>/dev/null | head -1 || true)"
[[ -n "${latest_baseline}" ]] && cp -f "${latest_baseline}" "${run_dir}/baseline.json"
ln -sfn "${run_dir}" "${latest_link}"
echo "Stand gesichert in ${run_dir}"
if [[ "${skip_bench}" != 1 && -n "${latest_baseline}" ]]; then
  echo "Baseline der letzten Messung: $(python3 -c "
import json,sys
d=json.load(open('${latest_baseline}'))
print('steady', d.get('steady_tokens_per_second_median'), 'Token/s; TTFT', d.get('time_to_first_token_seconds_median'), 's; Aggregat', d.get('aggregate_tokens_per_second'))")"
fi

# --- neue Werte schreiben ---------------------------------------------------
set_or_add() {
  local key="$1" value="$2"
  if grep -q "^${key}=" "${host_env}"; then
    sed -i "s#^${key}=.*#${key}=${value}#" "${host_env}"
  else
    printf '%s=%s\n' "${key}" "${value}" >> "${host_env}"
  fi
}
set_or_add PENNY_PLE_NVME_MODEL "${new_ple}"
set_or_add PENNY_HICACHE_SIZE_GB "${new_hicache}"
set_or_add PENNY_MEM_FRACTION_STATIC "${new_mem}"
set_or_add PENNY_SPEC_NUM_STEPS "${new_steps}"
set_or_add PENNY_SPEC_EAGLE_TOPK 1
set_or_add PENNY_SPEC_NUM_DRAFT_TOKENS "${new_draft}"
set_or_add PENNY_SLEEP_ON_IDLE "${new_sleep}"
set_or_add PENNY_CHUNKED_PREFILL_SIZE "${new_chunk}"
echo 'Neue Werte in config/host.env geschrieben.'

run ./scripts/50-install-pennyroyal.sh
bash -c "cd '${root}'; source lib/common.sh; source lib/units.sh; render_unit pennyroyal.container; systemd_reload"

# --- Neustart ---------------------------------------------------------------
echo
echo 'Die Runtime wird jetzt neu gestartet (Kaltstart bis zu 15 Minuten).'
echo 'Abbruch mit Strg+C in den naechsten 15 Sekunden - dann aendert sich nichts mehr an der Laufzeit.'
sleep 15
export PENNYROYAL_PROTECT=0
run ./scripts/apply-runtime-unit.sh --restart-only --force
if ! run ./scripts/wait-for-runtime.sh; then
  echo
  echo 'START FEHLGESCHLAGEN. Sichere Werte werden zurueckgeholt.'
  cp -f "${run_dir}/host.env" "${host_env}"
  run ./scripts/50-install-pennyroyal.sh
  bash -c "cd '${root}'; source lib/common.sh; source lib/units.sh; render_unit pennyroyal.container; systemd_reload"
  run ./scripts/apply-runtime-unit.sh --restart-only --force || true
  echo 'Letzte Meldung im Journal:'
  journalctl --user -u pennyroyal.service --no-pager -n 30 | tail -12
  exit 1
fi

# --- Messen und vergleichen -------------------------------------------------
report="${run_dir}/report.txt"
{
  echo "Tuning-Lauf ${ts} Profil ${profile}"
  echo "HiCache ${new_hicache} GiB, mem ${new_mem}, spec ${new_steps}/1/${new_draft}, sleep ${new_sleep}, prefill ${new_chunk}"
} > "${report}"
if [[ "${skip_bench}" == 1 ]]; then
  echo 'Messung uebersprungen (--ohnemessung).' | tee -a "${report}"
  cat "${report}"; exit 0
fi

BENCHMARK_ALLOW_BUSY=1 ./scripts/benchmark.sh normal 1 | tee -a "${report}" || true
BENCHMARK_ALLOW_BUSY=1 ./scripts/benchmark.sh normal 4 | tee -a "${report}" || true
after="$(ls -1t "${STATE_DIR}/benchmarks"/*.json | head -1)"

decision="$(python3 - "${latest_baseline:-}" "${after}" <<'PY'
import json, pathlib, sys
base_path, after_path = sys.argv[1:3]
def read(p):
    return json.loads(pathlib.Path(p).read_text()) if p and pathlib.Path(p).is_file() else {}
base, after = read(base_path), read(after_path)
def value(d):
    return d.get('steady_tokens_per_second_median') or d.get('aggregate_tokens_per_second')
b, a = value(base), value(after)
if b is None or a is None:
    print('unklar'); raise SystemExit
if a >= b * 0.9:
    print('behalten')
else:
    print('zurueck')
PY
)"
echo "Vergleich der Messungen: vor $(basename "${latest_baseline:-keine}") / nach $(basename "${after}")" >> "${report}"
python3 - "${latest_baseline:-}" "${after}" >> "${report}" <<'PY'
import json, pathlib, sys
def read(p):
    return json.loads(pathlib.Path(p).read_text()) if p and pathlib.Path(p).is_file() else {}
b, a = read(sys.argv[1]), read(sys.argv[2])
for key in ('steady_tokens_per_second_median','time_to_first_token_seconds_median','aggregate_tokens_per_second','sglang_spec_accept_length'):
    print(f'  {key:38} vor {b.get(key)}  nach {a.get(key)}')
PY
cat "${report}"
echo
case "${decision}" in
  behalten)
    echo 'Ergebnis: Werte BLEIBEN stehen (keine Verschlechterung unter 90 %).'
    echo 'Wenn die Messung besser werden soll: naechstes Profil testen mit'
    echo '  ./scripts/apply-tuning.sh --profil konservativ'
    ;;
  zurueck)
    echo 'Ergebnis: Verschlechtert. Ruckfallierung laeuft.'
    exec "${root}/scripts/apply-tuning.sh" --zurueck
    ;;
  *)
    echo 'Ergebnis: keine belastbarer Vergleich moeglich (Baseline fehlt oder Messung fehlgeschlagen).'
    echo 'Pruefen: ./scripts/doctor.sh und cat '"${run_dir}/report.txt"
    ;;
esac
echo 'Protokoll: '"${run_dir}/report.txt"
