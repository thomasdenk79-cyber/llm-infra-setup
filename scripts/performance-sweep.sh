#!/usr/bin/env bash
# Mehrstuendiger Durchsatz-/Kontext-Sweep.
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
mkdir -p state/benchmarks/sweep
log_file="state/benchmarks/sweep/$(date -u +%Y%m%dT%H%M%SZ).log"
exec > >(tee -a "$log_file") 2>&1

contexts=(20000 100000 250000 500000)
profiles=(sweet maxkv aggressiv c16)

wait_ready() { echo 'Warte auf Runtime...'; ./scripts/wait-for-runtime.sh; }

snapshot() {
  local profile="$1" context="$2" concurrency="$3" phase="$4" body max_tokens kv_used kv_avail pages gpu_util gpu_mem gpu_free gpu_power
  body="$(curl -fsS --max-time 8 http://127.0.0.1:8001/metrics || true)"
  max_tokens="$(awk '/^sglang:max_total_num_tokens(\{| )/ {print $2; exit}' <<<"$body")"
  kv_used="$(awk '/^sglang:kv_used_tokens(\{| )/ {print $2; exit}' <<<"$body")"
  kv_avail="$(awk '/^sglang:kv_available_tokens(\{| )/ {print $2; exit}' <<<"$body")"
  pages="$(awk '/^sglang:num_pages(\{| )/ {print $2; exit}' <<<"$body")"
  IFS=',' read -r gpu_util gpu_mem gpu_free gpu_power <<< "$(nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.free,power.draw --format=csv,noheader,nounits 2>/dev/null | head -1 || true)"
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' "$(date -u +%FT%TZ)" "$profile" "$context" "$concurrency" "$phase" "${max_tokens:-}" "${kv_used:-}" "${kv_avail:-}" "${pages:-}" "${gpu_util:-}" "${gpu_mem:-}" "${gpu_free:-}" "${gpu_power:-}" >> state/benchmarks/sweep/metrics.csv
}

metrics_header='timestamp,profile,target_context_tokens,concurrency,phase,max_total_num_tokens,kv_used_tokens,kv_available_tokens,num_pages,gpu_util_percent,gpu_memory_used_mib,gpu_memory_free_mib,gpu_power_watts'
if [[ -f state/benchmarks/sweep/metrics.csv ]] && [[ "$(head -1 state/benchmarks/sweep/metrics.csv)" != "$metrics_header" ]]; then
  mv state/benchmarks/sweep/metrics.csv "state/benchmarks/sweep/metrics-legacy-$(date -u +%Y%m%dT%H%M%SZ).csv"
fi
[[ -f state/benchmarks/sweep/metrics.csv ]] || echo "$metrics_header" > state/benchmarks/sweep/metrics.csv

for profile in "${profiles[@]}"; do
  wait_ready
  echo "=== Profil $profile ==="
  ./scripts/apply-tuning.sh --profil "$profile" --ohnemessung
  ./scripts/session-checkpoint.sh "Performance-Sweep: Profil $profile gestartet"
  wait_ready
  case "$profile" in
    maxkv) concurrencies=(1 2) ;;
    sweet) concurrencies=(1 2 3 4) ;;
    aggressiv) concurrencies=(1 2 4 6 8) ;;
    c16) concurrencies=(1 2 4 6 8 16) ;;
  esac
  for context in "${contexts[@]}"; do
    for concurrency in "${concurrencies[@]}"; do
      echo "=== $profile context=${context} concurrency=${concurrency} ==="
      snapshot "$profile" "$context" "$concurrency" before
      if ./scripts/benchmark.sh normal "$concurrency" "$context"; then
        snapshot "$profile" "$context" "$concurrency" after
      else
        echo 'WARNUNG: Benchmark fehlgeschlagen; naechsten Punkt versuchen.'
      fi
    done
  done
  ./scripts/session-checkpoint.sh "Performance-Sweep: Profil $profile abgeschlossen"
done
echo 'Sweep abgeschlossen. Ergebnisse: state/benchmarks/ und state/benchmarks/sweep/metrics.csv'
