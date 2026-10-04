#!/usr/bin/env bash
# Run PLE variants sequentially on the exclusive GPU and always restore Turbo C6.
# Usage: ./scripts/run-ple-variant-matrix.sh [--retry-failed]
set -Eeuo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$root/lib/common.sh"
source "$root/lib/units.sh"
retry_failed=0
[[ "${1:-}" == --retry-failed ]] && retry_failed=1
run_dir="$root/state/variant-runs/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$run_dir"
exec > >(tee -a "$run_dir/orchestrator.log") 2>&1
summary="$run_dir/summary.csv"
printf 'variant,result,detail\n' > "$summary"

log "Matrixlauf; Ergebnisse: $run_dir"

stop_gpu_services() {
  local service
  for service in sglang-turbo-upstream-ple.service sglang-turbo-variant-b.service \
    sglang-turbo-variant-d.service pennyroyal.service sglang-turbo-c6.service; do
    systemctl --user stop "$service" >/dev/null 2>&1 || true
  done
  sleep 5
  if nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null | rg -q '[0-9]'; then
    log 'GPU-Prozesse nach Stop noch vorhanden; warte 30 Sekunden.'
    sleep 30
  fi
}

capture_logs() {
  local variant="$1" service="$2" container="$3"
  local destination="$run_dir/$variant"
  mkdir -p "$destination"
  journalctl --user -u "$service" --since "$run_started" --no-pager -o short-iso \
    > "$destination/journal.log" 2>&1 || true
  podman logs --timestamps "$container" > "$destination/container.log" 2>&1 || true
  rg -n -i 'error|exception|traceback|cuda graph|capture|uncaptured|PLE NVMe|mean_read|health' \
    "$destination/journal.log" "$destination/container.log" > "$destination/interesting.log" || true
}

render_variant_unit() {
  local worktree="$1" unit="$2"
  REPO_ROOT="$worktree" UNIT_NAME="$unit" bash -c '
    set -Eeuo pipefail
    source "$REPO_ROOT/lib/common.sh"
    source "$REPO_ROOT/lib/units.sh"
    render_unit "$UNIT_NAME"
    systemd_reload
  '
}

wait_variant_ready() {
  local name="$1" service="$2" port="$3" deadline=$((SECONDS + 2700))
  while (( SECONDS < deadline )); do
    if ! systemctl --user is-active --quiet "$service"; then
      log "$name: Dienst ist vor Readiness beendet."
      return 1
    fi
    if curl -fsS --max-time 5 "http://127.0.0.1:$port/health" >/dev/null 2>&1; then
      log "$name: Health-Endpoint bereit auf Port $port."
      return 0
    fi
    sleep 15
  done
  log "$name: Readiness-Timeout nach 45 Minuten."
  return 1
}

run_benchmarks() {
  local name="$1" worktree="$2" port="$3" model="$4" profile="$run_dir/$1"
  mkdir -p "$profile"
  local concurrency
  for concurrency in 1 6; do
    log "$name: quick benchmark, concurrency=$concurrency"
    if ! (cd "$worktree" && BENCHMARK_MODEL="$model" PENNYROYAL_PORT="$port" \
      MIN_TOKENS=0 ./scripts/benchmark.sh quick "$concurrency") \
      > "$profile/benchmark-c${concurrency}.log" 2>&1; then
      log "$name: benchmark c$concurrency failed; continuing to next variant."
      return 1
    fi
  done
}

queue_healer() {
  local name="$1"
  "$root/scripts/ple-heal-failure.sh" "$name" "$run_dir" &
  log "$name: Luna-Heiler im Hintergrund gestartet (PID $!)."
}

run_one() {
  local name="$1" worktree="$2" installer="$3" unit="$4" service="$5" port="$6" container="$7" model="$8"
  local attempt=1 max_attempts=1
  (( retry_failed == 1 )) && max_attempts=2
  while (( attempt <= max_attempts )); do
    log "===== $name attempt $attempt/$max_attempts ====="
    stop_gpu_services
    run_started="$(date --iso-8601=seconds)"
    if ! (cd "$worktree" && "$installer"); then
      capture_logs "$name-attempt-$attempt" "$service" "$container"
      printf '%s,install_failed,attempt-%s\n' "$name" "$attempt" >> "$summary"
      queue_healer "$name"
      return 1
    fi
    if ! render_variant_unit "$worktree" "$unit"; then
      capture_logs "$name-attempt-$attempt" "$service" "$container"
      printf '%s,render_failed,attempt-%s\n' "$name" "$attempt" >> "$summary"
      queue_healer "$name"
      return 1
    fi
    if ! systemctl --user start "$service"; then
      capture_logs "$name-attempt-$attempt" "$service" "$container"
      printf '%s,start_failed,attempt-%s\n' "$name" "$attempt" >> "$summary"
      queue_healer "$name"
      attempt=$((attempt + 1)); continue
    fi
    if wait_variant_ready "$name" "$service" "$port"; then
      capture_logs "$name-attempt-$attempt" "$service" "$container"
      if run_benchmarks "$name" "$worktree" "$port" "$model"; then
        printf '%s,passed,attempt-%s\n' "$name" "$attempt" >> "$summary"
        return 0
      fi
      printf '%s,benchmark_failed,attempt-%s\n' "$name" "$attempt" >> "$summary"
      return 1
    fi
    capture_logs "$name-attempt-$attempt" "$service" "$container"
    printf '%s,crashed_or_timeout,attempt-%s\n' "$name" "$attempt" >> "$summary"
    queue_healer "$name"
    attempt=$((attempt + 1))
  done
  return 1
}

restore_production() {
  log 'Räume Vergleichsdienste auf und starte Produktionsdienst auf Port 8002.'
  stop_gpu_services
  rm -f "$UNIT_DIR/sglang-turbo-upstream-ple.container" \
    "$UNIT_DIR/sglang-turbo-variant-b.container" \
    "$UNIT_DIR/sglang-turbo-variant-d.container"
  rm -f "$WANTS_DIR/sglang-turbo-upstream-ple.container" \
    "$WANTS_DIR/sglang-turbo-variant-b.container" \
    "$WANTS_DIR/sglang-turbo-variant-d.container"
  systemd_reload
  REPO_ROOT="$root" UNIT_NAME=sglang-turbo-c6.container bash -c '
    set -Eeuo pipefail
    source "$REPO_ROOT/lib/common.sh"
    source "$REPO_ROOT/lib/units.sh"
    render_unit "$UNIT_NAME"
    systemd_reload
  '
  systemctl --user start sglang-turbo-c6.service || true
  wait_variant_ready PROD sglang-turbo-c6.service 8002 || true
}

trap restore_production EXIT INT TERM

overall=0
run_one A "$root/../llm-infra-setup-turbo-upstream" ./scripts/52-install-sglang-turbo-upstream-ple.sh \
  sglang-turbo-upstream-ple.container sglang-turbo-upstream-ple.service 8003 sglang-turbo-upstream-ple Qwen3.8-Flash-Next || overall=1
run_one B "$root/../llm-infra-setup-variant-b" ./scripts/53-install-sglang-turbo-variant-b.sh \
  sglang-turbo-variant-b.container sglang-turbo-variant-b.service 8004 sglang-turbo-variant-b Qwen3.8-Flash-Next || overall=1
run_one D "$root/../llm-infra-setup-variant-d" ./scripts/54-install-sglang-turbo-variant-d.sh \
  sglang-turbo-variant-d.container sglang-turbo-variant-d.service 8005 sglang-turbo-variant-d Qwen3.8-Flash-Next || overall=1
run_one C "$root/../llm-infra-setup-pennyroyal" ./scripts/50-install-pennyroyal.sh \
  pennyroyal.container pennyroyal.service 8001 pennyroyal Qwen3.8-Flash-Next || overall=1

log 'Variantenlauf abgeschlossen.'
column -t -s, "$summary" || cat "$summary"
exit "$overall"
