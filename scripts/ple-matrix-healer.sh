#!/usr/bin/env bash
# Qwen-Wächter für den Matrix-Orchestrator. Prüft Runner, Messung und Umgebung
# nach jeder Runde und lässt nur validierte, committete Korrekturen zu.
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
out="$root/state/matrix-healer/$stamp"
mkdir -p "$out"
lock="$root/state/matrix-healer/.lock"
if ! mkdir "$lock" 2>/dev/null; then
  echo "Matrix-Heiler läuft bereits; überspringe diese Runde." >&2
  exit 0
fi
trap 'rmdir "$lock" 2>/dev/null || true' EXIT
# Vorpruefung: Qwen laeuft ueber LiteLLM (Port 4000) auf einer gesunden
# Produktionsruntime (Pennyroyal 8001 oder Turbo 8002). Ohne die beiden waere die
# Stunde Laufzeit nur ein stummer Fehlerritt gegen eine tote API.
_caller_litellm_port="${LITELLM_PORT:-}"
[[ -f "$root/config/host.env" ]] && source "$root/config/host.env"
LITELLM_PORT="${_caller_litellm_port:-${LITELLM_PORT:-4000}}"
prod_ready=0
for candidate in 8001 8002; do
  curl -fsS --max-time 5 "http://127.0.0.1:${candidate}/health" >/dev/null 2>&1 && { prod_ready=1; break; }
done
if (( prod_ready == 0 )); then
  echo "Matrix-Heiler verschoben: kein Produktionsdienst auf 8001/8002 erreichbar. Naechster Befehl: ./scripts/doctor.sh" >&2
  exit 0
fi
if ! curl -fsS --max-time 5 "http://127.0.0.1:${LITELLM_PORT}/health" >/dev/null 2>&1 \
   && ! curl -fsS --max-time 5 "http://127.0.0.1:${LITELLM_PORT}/health/liveness" >/dev/null 2>&1; then
  echo "Matrix-Heiler verschoben: LiteLLM auf ${LITELLM_PORT} nicht erreichbar. Naechster Befehl: ./scripts/doctor.sh" >&2
  exit 0
fi
prompt="$(cat <<EOF
Du bist der autonome Qwen-Architekt und Implementierer. Prüfe im Repository $root die soeben abgeschlossene Matrixrunde und die gesamte
Umgebung. Lies den neuesten Ordner unter state/variant-runs, state/benchmarks,
state/research-audits und state/matrix-healer. Prüfe besonders
scripts/run-ple-variant-matrix.sh, scripts/ple-matrix-supervisor.sh,
scripts/ple-heal-failure.sh, scripts/ple-research-audit.sh,
scripts/benchmark.sh und scripts/benchmark_probe.py auf falsche Ports,
Readiness- und Drain-Rennen, endlose Wartepfade, falsche Erfolgsmarkierungen,
falsche Token/s-Metriken und fehlende Wiederaufnahme nach Fehlern.
Untersuche zusätzlich die Startzeit jedes Dienstes: Gewichts- und Draft-Ladezeit,
PLE-Page-Cache, Linux-/ZFS-Cache, Triton-/FlashInfer-Caches, CUDA-Graph-Capture
und wiederholte Warmups. Entwickle bei Bedarf eine eigene Startup-Cache-Variante;
der Runner darf Preload-Schritte nicht nur ausgeben, sondern muss sie sicher,
idempotent und vor dem Start ausführen.
Baue außerdem schnelle Vorab-Gates vor jeden teuren GPU-Start: Shell-/Python-
Syntax, Varianten-Drift, doppelte oder widersprüchliche SGLang-Argumente,
verfügbare Modell-/PLE-Pfade, importierbare Overlay-Module und einen CPU-/
Container-Smoke-Test für Warmup-Registrierungen. Ein Fehler muss in Sekunden
als preflight_failed erscheinen und darf keinen 10-Minuten-GPU-Start auslösen.

Arbeite autonom: repariere belegte Fehler direkt, entscheide über Architektur
und Varianten und implementiere die nötigen Änderungen. Stoppe oder starte keine Pods und ändere keine
Runtime-Units. Implementiere sichere minimale Korrekturen an Runnern,
Heilern, Benchmarks oder Dokumentation. Führe bash -n, make validate und bei
Unit-Bezug make drift aus. Committe jede Änderung präzise. Schreibe Befunde,
Änderungen, Commit und offene Risiken nach $out/report.md. Wenn alles stimmt,
schreibe das ausdrücklich und ändere nichts.

Bewerte ausdrücklich einen Kandidaten "Pennyroyal-Turbo-Hybrid": Pennyroyal
bleibt die unveränderte SSD/NIXL-Basis; Turbo-Ideen wie
Mamba-Cache-Strategie, lazy/extra-buffer, MXFP8-/FlashInfer-Parameter,
Chunked-Prefill und CUDA-Graph-Batchgrößen werden nur als isolierte
Konfigurationsvariante getestet. Kopiere keinen Turbo-PLE-Pythonlader in
Pennyroyal. Wenn die Logs oder Messwerte dafür sprechen, lege einen eigenen
Branch und Worktree an, dokumentiere die Hypothese und trage die Variante in
die Matrixplanung ein. Wenn nicht, begründe das im Bericht.
EOF
)"
timeout --signal=INT --kill-after=60s "${PLE_MATRIX_HEALER_MAX_SECONDS:-3600}" \
  opencode run --dir "$root" --model local-litellm/qwen3.8-flash-next \
  --agent build --auto "$prompt" >"$out/opencode.log" 2>&1 || true
echo "Matrix-Heiler abgeschlossen: $out"
