#!/usr/bin/env bash
# Benchmark mit trenntlicher Messung von Vorlaufzeit und Schreibgeschwindigkeit.
#
#   ./scripts/benchmark.sh                 schneller Test (quick)
#   ./scripts/benchmark.sh normal          mittlerer Prompt
#   ./scripts/benchmark.sh long            langer Prompt
#   ./scripts/benchmark.sh quick 4         4 gleichzeitige Anfragen
#   ./scripts/benchmark.sh normal 4 20000  4 Anfragen mit ca. 20k Prompt-Token
#   MIN_TOKENS=150 ./scripts/benchmark.sh  # Bruch bei zu geringer Geschwindigkeit
#
# Warum zwei Zahlen?
#   time_to_first_token      = Wartezeit, bis das erste Wort erscheint (Vorlauf)
#   overall_tokens_per_second = End-to-end-Durchsatz inklusive Vorlauf
#   steady_tokens_per_second = diagnostische Schreibgeschwindigkeit danach
# Der alte "tokens_per_second"-Wert enthielt beides gemischt und war deshalb zu
# klein. Er wird weiter mitgeführt, damit aeltere Messreihen vergleichbar bleiben.
#
# Ergebnis: state/benchmarks/<zeitstempel>.json und .md plus Verlauf in
#           state/benchmarks/history.csv
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${root}/lib/common.sh"
[[ -f "${root}/config/host.env" ]] && source "${root}/config/host.env"
: "${PENNYROYAL_PORT:=8001}"
: "${BENCHMARK_MODEL:=pennyroyal}"
: "${MIN_TOKENS:=0}"
profile="${1:-quick}"
concurrency="${2:-1}"
target_context_tokens="${3:-}"
mkdir -p "${root}/state/benchmarks"
base_url="http://127.0.0.1:${PENNYROYAL_PORT}/v1"

case "${profile}" in
  quick)  prompt='Erkläre ZFS in einem Satz.'; max_tokens=256; repeat=1 ;;
  normal) prompt='Fasse die Architektur eines lokalen LLM-Stacks mit Podman, ZFS und LiteLLM zusammen.'; max_tokens=1024; repeat=60 ;;
  long)   prompt='Analysiere Gruende fuer Durchsatzgrenzen bei grossen Sprachmodellen.'; max_tokens=1500; repeat=400 ;;
  *) echo 'usage: benchmark.sh [quick|normal|long] [gleichzeitig]' >&2; exit 2 ;;
esac

if [[ -n "${target_context_tokens}" ]]; then
  [[ "${target_context_tokens}" =~ ^[1-9][0-9]*$ ]] || { echo 'Kontextziel muss eine positive Zahl sein.' >&2; exit 2; }
  # The repeated prompt is deliberately simple and deterministic. The API
  # reports the actual prompt_tokens; that value is authoritative in the
  # resulting JSON, while this estimate chooses the repeat count.
  chars_per_token=4
  base_chars=${#prompt}
  repeat=$(( (target_context_tokens * chars_per_token + base_chars - 1) / base_chars ))
  (( repeat > 0 )) || repeat=1
fi

running="$(curl -fsS --max-time 5 "http://127.0.0.1:${PENNYROYAL_PORT}/metrics" 2>/dev/null || true)"
running="$(printf '%s\n' "${running}" \
  | awk '/^sglang:num_running_reqs\{/ {print $2; found=1} END{if(!found) print "0"}')"
if [[ "${running%.*}" != 0 ]]; then
  printf 'ACHTUNG: es laufen bereits %s Anfragen; Messung wird ungenau.\n' "${running}" >&2
  printf '         Warten oder mit BENCHMARK_ALLOW_BUSY=1 trotzdem messen.\n' >&2
  if [[ "${BENCHMARK_ALLOW_BUSY:-0}" != 1 ]]; then
    for _ in $(seq 1 12); do
      sleep 5
      running="$(curl -fsS --max-time 5 "http://127.0.0.1:${PENNYROYAL_PORT}/metrics" 2>/dev/null || true)"
      running="$(printf '%s\n' "${running}" | awk '/^sglang:num_running_reqs\{/ {print $2; exit}')"
      [[ "${running:-0}" == "0" || "${running:-0}" == "0.0" ]] && break
    done
  fi
fi

printf 'Aufwaermens (zaehlt nicht in die Messung) ...\n'
"${root}/scripts/benchmark_probe.py" --base-url "${base_url}" --model "${BENCHMARK_MODEL}" \
  --prompt 'Antworte mit genau einem Wort.' --max-tokens 8 >/dev/null 2>&1 || true

ts="$(date -u +%Y%m%dT%H%M%SZ)"
json_out="${root}/state/benchmarks/${ts}.json"
md_out="${root}/state/benchmarks/${ts}.md"
workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT

printf 'Starte %s Anfrage(n) im Profil %s ...\n' "${concurrency}" "${profile}"
wall_start="$(date +%s%3N)"
for i in $(seq 1 "${concurrency}"); do
  # Keep prompt length equivalent while preventing shared-prefix/KV reuse from
  # making a parallel run look faster than independent requests.
  request_prompt="${prompt} [benchmark-request-${i}]"
  "${root}/scripts/benchmark_probe.py" --base-url "${base_url}" --model "${BENCHMARK_MODEL}" \
    --prompt "${request_prompt}" --prompt-repeat "${repeat}" --max-tokens "${max_tokens}" --sample-metrics \
    > "${workdir}/${i}.json" 2>"${workdir}/${i}.err" &
done
errors=0
for pid in $(jobs -pr); do wait "${pid}" || errors=$((errors + 1)); done
wall_ms=$(( $(date +%s%3N) - wall_start ))

python3 - "${workdir}" "${json_out}" "${profile}" "${concurrency}" "${wall_ms}" "${errors}" "${target_context_tokens}" <<'PY'
import json, pathlib, statistics, sys
work, out, profile, conc, wall_ms, errors = sys.argv[1:7]
runs = []
for p in sorted(pathlib.Path(work).glob('*.json')):
    try:
        runs.append(json.loads(p.read_text()))
    except Exception:
        pass
ok = [r for r in runs if r.get('ok')]
def q(vals, frac):
    if not vals:
        return None
    if len(vals) == 1:
        return round(vals[0], 3)
    return round(statistics.quantiles(vals, n=100, method='inclusive')[min(99, int(frac * 100))], 3)
tokens = sum(r.get('completion_tokens') or 0 for r in ok)
doc = {
    'timestamp': pathlib.Path(out).stem,
    'profile': profile,
    'target_context_tokens': int(sys.argv[7]) if sys.argv[7] else None,
    'concurrency': int(conc),
    'errors': int(errors),
    'requests_ok': len(ok),
    'wall_ms': int(wall_ms),
    'completion_tokens_total': tokens,
    'aggregate_tokens_per_second': round(tokens / (int(wall_ms) / 1000), 2) if int(wall_ms) else None,
    'end_to_end_tokens_per_second': round(tokens / (int(wall_ms) / 1000), 2) if int(wall_ms) else None,
    'time_to_first_token_seconds_median': q([r['time_to_first_token_seconds'] for r in ok], 0.50),
    'time_to_first_token_seconds_p95': q([r['time_to_first_token_seconds'] for r in ok], 0.95),
    'steady_tokens_per_second_median': q([r['steady_tokens_per_second'] for r in ok], 0.50),
    'steady_tokens_per_second_p95': q([r['steady_tokens_per_second'] for r in ok], 0.95),
    'tokens_per_second': round(tokens / (int(wall_ms) / 1000), 2) if int(wall_ms) else None,
    'sglang_spec_accept_length': next((r.get('sglang_spec_accept_length') for r in ok if r.get('sglang_spec_accept_length') is not None), None),
    'sglang_gen_throughput_sample': next((r.get('sglang_gen_throughput_now') for r in ok if r.get('sglang_gen_throughput_now') is not None), None),
    'gpu_after': next((r.get('gpu_after') for r in ok if r.get('gpu_after')), {}),
    'runs': runs,
}
pathlib.Path(out).write_text(json.dumps(doc, indent=2, ensure_ascii=False) + '\n')
print(json.dumps({k: doc[k] for k in ('steady_tokens_per_second_median', 'time_to_first_token_seconds_median', 'aggregate_tokens_per_second', 'requests_ok', 'errors')}))
PY

steady="$(python3 -c "import json,sys;print(json.load(open('${json_out}'))['steady_tokens_per_second_median'] or 0)")"
cat > "${md_out}" <<EOF2
# Benchmark ${ts}

| Messgroesse | Wert | Bedeutung |
|---|---|---|
| Vorlaufzeit bis zum ersten Token (Median) | $(python3 -c "import json;d=json.load(open('${json_out}'));print(d['time_to_first_token_seconds_median'])") s | Warten, bevor etwas erscheint |
| End-to-end-Durchsatz | $(python3 -c "import json;d=json.load(open('${json_out}'));print(d['end_to_end_tokens_per_second'])") Token/s | Primäre Vergleichszahl inklusive Vorlauf |
| SGLang-Gen-Durchsatz (Momentaufnahme) | $(python3 -c "import json;d=json.load(open('${json_out}'));print(d['sglang_gen_throughput_sample'])") Token/s | Server-Metrik über laufende Decodes |
| Diagnostische Schreibgeschwindigkeit | ${steady} Token/s | Ohne Vorlauf; nicht als End-to-end-Wert vergleichen |
| Gesamt durchsatz (alle Anfragen) | $(python3 -c "import json;d=json.load(open('${json_out}'));print(d['aggregate_tokens_per_second'])") Token/s | Wie viel das System insgesamt schafft |
| Spekulativ akzeptiert je Schritt | $(python3 -c "import json;d=json.load(open('${json_out}'));print(d['sglang_spec_accept_length'])") | gross = Modell raeumt schnell voraus |
| Anfragen ok / Fehler | $(python3 -c "import json;d=json.load(open('${json_out}'));print(d['requests_ok'],'/',d['errors'])") |  |
| GPU hinterher | $(python3 -c "import json;d=json.load(open('${json_out}'));g=(d['gpu_after'].get('gpus') or [{}])[0];print(f\"{g.get('utilization_percent','-')} % Auslastung, {g.get('memory_used_mib','-')} MiB VRAM, {g.get('power_watts','-')} W\")" ) |  |

Einordnung, warum Zahlen liegen, wie sie liegen: docs/performance.md
Maschinenlesbar: $(basename "${json_out}")
EOF2
cat "${md_out}"

{
  f="${root}/state/benchmarks/history.csv"
  [[ -f "${f}" ]] || printf 'timestamp,profile,concurrency,steady_tok_s,ttft_median_s,aggregate_tok_s,requests,errors\n' > "${f}"
  python3 -c "
import json
d=json.load(open('${json_out}'))
print(','.join(str(x) for x in (d['timestamp'],d['profile'],d['concurrency'],d['steady_tokens_per_second_median'],d['time_to_first_token_seconds_median'],d['aggregate_tokens_per_second'],d['requests_ok'],d['errors'])))
" >> "${f}"
}

if [[ "${MIN_TOKENS}" != 0 ]]; then
  awk -v got="${steady}" -v min="${MIN_TOKENS}" 'BEGIN { exit (got+0 >= min+0 ? 0 : 1) }' \
    || { printf '\nUNTERSCHREITEN: %s Token/s < geforderte %s Token/s\n' "${steady}" "${MIN_TOKENS}" >&2; exit 1; }
  printf '\nGrenze erfuellt: %s >= %s Token/s\n' "${steady}" "${MIN_TOKENS}"
fi
