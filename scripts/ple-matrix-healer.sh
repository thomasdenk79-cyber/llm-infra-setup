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
prompt="$(cat <<EOF
Prüfe im Repository $root die soeben abgeschlossene Matrixrunde und die gesamte
Umgebung. Lies den neuesten Ordner unter state/variant-runs, state/benchmarks,
state/research-audits und state/matrix-healer. Prüfe besonders
scripts/run-ple-variant-matrix.sh, scripts/ple-matrix-supervisor.sh,
scripts/ple-heal-failure.sh, scripts/ple-research-audit.sh,
scripts/benchmark.sh und scripts/benchmark_probe.py auf falsche Ports,
Readiness- und Drain-Rennen, endlose Wartepfade, falsche Erfolgsmarkierungen,
falsche Token/s-Metriken und fehlende Wiederaufnahme nach Fehlern.

Arbeite nur im Hauptrepository. Stoppe oder starte keine Pods und ändere keine
Runtime-Units. Implementiere sichere minimale Korrekturen an Runnern,
Heilern, Benchmarks oder Dokumentation. Führe bash -n, make validate und bei
Unit-Bezug make drift aus. Committe jede Änderung präzise. Schreibe Befunde,
Änderungen, Commit und offene Risiken nach $out/report.md. Wenn alles stimmt,
schreibe das ausdrücklich und ändere nichts.
EOF
)"
timeout --signal=INT --kill-after=60s "${PLE_MATRIX_HEALER_MAX_SECONDS:-3600}" \
  opencode run --dir "$root" --model local-litellm/qwen3.8-flash-next \
  --agent build --auto "$prompt" >"$out/opencode.log" 2>&1 || true
echo "Matrix-Heiler abgeschlossen: $out"
