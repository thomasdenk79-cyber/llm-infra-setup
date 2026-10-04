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
  local idle_since=0 deadline=$((SECONDS + 1800)) drained=0
  local drain_seconds="${GPU_DRAIN_IDLE_SECONDS:-120}"
  log 'Warte auf einen ruhigen Anfragezustand vor dem GPU-Stop.'
  while (( SECONDS < deadline )); do
    local busy=0 port metrics running queued agents
    for port in 8001 8002 8003 8004 8005; do
      metrics="$(curl -fsS --max-time 2 "http://127.0.0.1:$port/metrics" 2>/dev/null || true)"
      [[ -n "$metrics" ]] || continue
      running="$(awk -F' ' '/sglang:num_running_reqs\{/ {print $NF; exit}' <<<"$metrics")"
      queued="$(awk -F' ' '/sglang:num_queue_reqs\{/ {print $NF; exit}' <<<"$metrics")"
      [[ "${running:-0}" =~ ^[0-9.]+$ ]] && awk -v v="$running" 'BEGIN{exit !(v>0)}' && busy=1
      [[ "${queued:-0}" =~ ^[0-9.]+$ ]] && awk -v v="$queued" 'BEGIN{exit !(v>0)}' && busy=1
    done
    # Nur echte Inferenz-Nutzer blockieren; die Heiler- und Pruefskripte selbst
    # gehren der Matrix und wuerden den Drain sonst dauerhaft auf Halten.
    # Eigene Heiler warten absichtlich auf das Ende der Matrix und dürfen den
    # GPU-Drain deshalb nicht gegenseitig blockieren. Nur fremde Agenten zählen.
    agents=0
    while IFS= read -r agent_line; do
      [[ "$agent_line" == *"run-ple-variant-matrix.sh"* ||
         "$agent_line" == *"ple-heal-failure.sh"* ||
         "$agent_line" == *"ple-research-audit.sh"* ||
         "$agent_line" == *"ple-matrix-healer.sh"* ]] && continue
      (( agents += 1 ))
    done < <(pgrep -af 'opencode run|codex exec' || true)
    (( agents > 0 )) && busy=1
    if (( busy == 1 )); then
      idle_since=0
    elif (( idle_since == 0 )); then
      idle_since=$SECONDS
      log 'Keine laufenden oder wartenden Requests; Drain-Timer gestartet.'
    elif (( SECONDS - idle_since >= drain_seconds )); then
      log "Anfrage- und Agenten-Drain ${drain_seconds} Sekunden stabil; GPU-Stop darf beginnen."
      drained=1
      break
    fi
    sleep 15
  done
  if (( drained == 0 )); then
    log 'Drain-Timeout nach 30 Minuten; stoppe trotzdem kontrolliert.'
  fi
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
  local name="$1" service="$2" port="$3" container="$4"
  local ready_timeout="${PLE_VARIANT_READY_TIMEOUT_SECONDS:-1800}"
  local deadline=$((SECONDS + ready_timeout))
  while (( SECONDS < deadline )); do
    local service_status container_status
    service_status="$(systemctl --user is-active "$service" 2>/dev/null || true)"
    case "$service_status" in
      active|activating|reloading) ;;
      *)
        log "$name: Dienst ist vor Readiness beendet (Status '$service_status')."
        return 1
        ;;
    esac
    container_status="$(podman inspect --format '{{.State.Status}}' "$container" 2>/dev/null || true)"
    # Leer und created zaehlen als Hochfahrphase; erst exited/dead/parked brechen ab.
    if [[ -n "$container_status" && "$container_status" != running && "$container_status" != created ]]; then
      log "$name: Containerstatus ist '$container_status'; Readiness abgebrochen."
      return 1
    fi
    if curl -fsS --max-time 5 "http://127.0.0.1:$port/health" >/dev/null 2>&1; then
      log "$name: Health-Endpoint bereit auf Port $port."
      return 0
    fi
    sleep 15
  done
  log "$name: Readiness-Timeout nach $((ready_timeout / 60)) Minuten."
  return 1
}

preflight_variant() {
  local name="$1" worktree="$2"
  log "$name: CPU-Vorprüfung vor GPU-Start."
  if ! (cd "$worktree" && timeout --signal=TERM --kill-after=10s \
      "${PLE_PREFLIGHT_TIMEOUT_SECONDS:-180}" make validate && \
      timeout --signal=TERM --kill-after=10s \
      "${PLE_PREFLIGHT_TIMEOUT_SECONDS:-180}" make drift); then
    log "$name: preflight_failed (validate/drift); kein teurer GPU-Start."
    return 1
  fi
  log "$name: CPU-Vorprüfung bestanden."
}

run_benchmarks() {
  local name="$1" worktree="$2" port="$3" model="$4" profile="$run_dir/$1"
  mkdir -p "$profile"
  local concurrency
  for concurrency in 1 6; do
    log "$name: quick benchmark, concurrency=$concurrency"
    if ! (cd "$root" && BENCHMARK_MODEL="$model" PENNYROYAL_PORT="$port" \
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
    if ! preflight_variant "$name" "$worktree"; then
      printf '%s,preflight_failed,attempt-%s\n' "$name" "$attempt" >> "$summary"
      queue_healer "$name"
      return 1
    fi
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
    if wait_variant_ready "$name" "$service" "$port" "$container"; then
      capture_logs "$name-attempt-$attempt" "$service" "$container"
      if run_benchmarks "$name" "$worktree" "$port" "$model"; then
        printf '%s,passed,attempt-%s\n' "$name" "$attempt" >> "$summary"
        "$root/scripts/record-variant-success.sh" "$name" "$worktree" "$run_dir" "$attempt" || \
          log "$name: Erfolgs-Commit/Tag konnte nicht erstellt werden."
        return 0
      fi
      printf '%s,benchmark_failed,attempt-%s\n' "$name" "$attempt" >> "$summary"
      capture_logs "$name-attempt-$attempt" "$service" "$container"
      queue_healer "$name"
      stop_gpu_services
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
  export REPO_ROOT="$root" UNIT_NAME=sglang-turbo-c6.container
  source "$root/lib/common.sh"
  source "$root/lib/units.sh"
  render_unit "$UNIT_NAME"
  systemd_reload
  systemctl --user start sglang-turbo-c6.service || true
  # Die Produktions-Unit sglang-turbo-c6 exponiert gemaess quadlet/sglang-turbo-c6.container
  # den Host-Port 8002 (8001 gehoert zu Pennyroyal). Der alte Default 8001 lies die
  # Restore-Readiness jedes Mal vollstaendig in den 45-Minuten-Timeout laufen.
  wait_variant_ready PROD sglang-turbo-c6.service "${PROD_HOST_PORT:-8002}" sglang-turbo-c6 || true
}

trap 'restore_production' EXIT
trap 'exit 130' INT TERM

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
