#!/usr/bin/env bash
# Analyse und Reparatur einer fehlgeschlagenen PLE-Variante.
set -Eeuo pipefail
variant="${1:?Variante A, B, C oder D fehlt}"
run_dir="$(realpath -- "${2:?Laufverzeichnis fehlt}")"
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
case "$variant" in
  A) worktree="$root/../llm-infra-setup-turbo-upstream" ;;
  B) worktree="$root/../llm-infra-setup-variant-b" ;;
  C) worktree="$root/../llm-infra-setup-pennyroyal" ;;
  D) worktree="$root/../llm-infra-setup-variant-d" ;;
  *) echo "Unbekannte Variante: $variant" >&2; exit 2 ;;
esac
mkdir -p "$run_dir/healing"
lock="$run_dir/healing/$variant.lock"
if ! mkdir "$lock" 2>/dev/null; then echo "$variant: Reparatur läuft bereits."; exit 0; fi
trap 'rmdir "$lock" 2>/dev/null || true' EXIT
log="$run_dir/healing/$variant.log"
exec > >(tee -a "$log") 2>&1
evidence="$run_dir/healing/$variant-evidence.txt"
cat "$run_dir/$variant"-attempt-*/interesting.log > "$evidence" 2>/dev/null || true
prompt_file="$run_dir/healing/$variant-luna-prompt.txt"
cat > "$prompt_file" <<EOF
Arbeite im Repository $worktree auf dem Variantenbranch $variant.
Die Variante ist beim Start oder Capture beendet worden. Belege liegen in
$evidence. Analysiere Ursache und implementiere eine minimale Reparatur, die
SSD-PLE und CUDA-Graph-Korrektheit erhält. Ändere keine Produktions-Units,
starte keine Pods und führe keinen Benchmark aus. Führe make validate und,
falls Units betroffen sind, make drift aus. Dokumentiere Ursache, Patch und
Restrisiko in der Varianten-Doku, committe den Worktree und gib Commit/Dateien aus.

Arbeite im Forschungsmodus: Wenn du einen plausiblen besseren Upstream-Patch,
ein Paper, einen offiziellen CUDA-/SGLang-Ansatz oder ein Plugin findest, prüfe
die Primärquelle im Internet. Übernimm nichts ungeprüft. Dokumentiere Quelle,
Datum, erwarteten Gewinn und Risiko in docs/research-loop.md. Wenn der Ansatz
eine zusätzliche Variante rechtfertigt, lege dafür einen eigenen Branch und
Worktree mit sprechendem Namen an und beschreibe die nötigen Runner-Einträge;
ändere die laufende Produktionsvariante nicht. Neue Forschungskandidaten
werden erst nach denselben Validate-, Start-, Health- und Benchmark-Gates
Kandidaten für die Produktion.
EOF
echo "Luna-Reparatur für $variant startet."
(cd "$worktree" && timeout --signal=INT --kill-after=60s \
  "${LUNA_MAX_SECONDS:-7200}" codex exec -m gpt-6-luna -C "$worktree" \
  --dangerously-bypass-approvals-and-sandbox < "$prompt_file") || \
  echo "Luna konnte $variant nicht reparieren."

# Qwen läuft über LiteLLM (Port 4000); dafür genügt jede gesunde lokale Produktionsruntime.
# Pennyroyal (8001) wird bevorzugt, Turbo (8002) ist der Fallback.
_caller_litellm_port="${LITELLM_PORT:-}"
[[ -f "$root/config/host.env" ]] && source "$root/config/host.env"
LITELLM_PORT="${_caller_litellm_port:-${LITELLM_PORT:-4000}}"

# Die Matrix hält die GPU exklusiv. Ein Qwen-Review mittendurch würde die laufende
# Messung verfälschen und beim nächsten GPU-Stop abgewürgt; erst darf es starten.
matrix_deadline=$((SECONDS + ${HEALER_MATRIX_WAIT_SECONDS:-10800}))
while pgrep -f 'run-ple-variant-matrix\.sh' >/dev/null 2>&1 \
   || systemctl --user is-active --quiet ple-variant-matrix.service 2>/dev/null; do
  if (( SECONDS >= matrix_deadline )); then break; fi
  sleep 30
done

gateway_ready() {
  curl -fsS --max-time 5 "http://127.0.0.1:${LITELLM_PORT}/health" >/dev/null 2>&1 \
    || curl -fsS --max-time 5 "http://127.0.0.1:${LITELLM_PORT}/health/liveness" >/dev/null 2>&1
}
probe_prod() {
  prod_port=""
  local candidate
  for candidate in 8001 8002; do
    if curl -fsS --max-time 5 "http://127.0.0.1:${candidate}/health" >/dev/null 2>&1; then
      prod_port="$candidate"
      return 0
    fi
  done
  return 1
}
prod_port="${HEALER_PROD_PORT:-}"
if [[ -n "$prod_port" ]] && ! curl -fsS --max-time 5 "http://127.0.0.1:${prod_port}/health" >/dev/null 2>&1; then
  prod_port=""
fi
# Endloses Warten vermeiden: maximal 20 Minuten auf eine gesunde Produktionsruntime.
probe_deadline=$((SECONDS + ${HEALER_PROD_WAIT_SECONDS:-1200}))
while [[ -z "$prod_port" ]] && (( SECONDS < probe_deadline )); do
  probe_prod || sleep 15
done
if (( SECONDS >= matrix_deadline )) && ( pgrep -f 'run-ple-variant-matrix\.sh' >/dev/null 2>&1 \
     || systemctl --user is-active --quiet ple-variant-matrix.service 2>/dev/null ); then
  echo "Qwen-Review verschoben: Matrixlauf hält die GPU noch immer (Timeout abgelaufen). Naechster Befehl: ./scripts/ple-matrix-supervisor.sh beobachten."
elif [[ -n "$prod_port" ]] && gateway_ready; then
  qwen_prompt="Prüfe den Reparaturstand der Variante $variant in $worktree. Lies $evidence und die letzten Commits. Suche Restfehler beim Breakable-CUDA-Graphen und SSD-PLE. Arbeite nur im Variantenbranch, ändere keine Produktionsdateien, starte keine Pods und benchmarke nicht. Korrigiere nötige Restfehler, führe make validate/make drift aus und committe. Forschungsmodus: Wenn ein offizieller Upstream-/Paper-/CUDA-/SGLang-/Plugin-Ansatz oder eine Kombination plausibel besser ist, recherchiere die Primärquelle im Internet, dokumentiere URL, Datum, Nutzen und Risiko in docs/research-loop.md und beschreibe eine neue isolierte Variante mit eigenem Branch/Worktree. Übernehme sie nicht ungeprüft in Produktion; sie braucht dieselben Validate-, Start-, Health- und Benchmark-Gates."
  (cd "$worktree" && timeout --signal=INT --kill-after=60s \
    "${OPENCODE_MAX_SECONDS:-5400}" opencode run --dir "$worktree" \
    --model local-litellm/qwen3.8-flash-next --agent build --auto "$qwen_prompt") \
    > "$run_dir/healing/$variant-qwen.log" 2>&1 || true
else
  echo "Qwen-Review verschoben: kein Produktionsdienst auf 8001/8002 oder LiteLLM auf ${LITELLM_PORT} war bereit. Naechster Befehl: ./scripts/doctor.sh"
fi
touch "$run_dir/healing/$variant.done"
echo "Reparaturlauf $variant beendet."
