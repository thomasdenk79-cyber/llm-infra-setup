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
(cd "$worktree" && codex exec -m gpt-6-luna -C "$worktree" \
  --dangerously-bypass-approvals-and-sandbox < "$prompt_file") || \
  echo "Luna konnte $variant nicht reparieren."

# Das lokale Qwen-Modell benötigt die wiederhergestellte GPU auf Port 8002.
for _ in $(seq 1 180); do
  curl -fsS --max-time 5 http://127.0.0.1:8002/health >/dev/null 2>&1 && break
  sleep 30
done
if curl -fsS --max-time 5 http://127.0.0.1:8002/health >/dev/null 2>&1; then
  qwen_prompt="Prüfe den Reparaturstand der Variante $variant in $worktree. Lies $evidence und die letzten Commits. Suche Restfehler beim Breakable-CUDA-Graphen und SSD-PLE. Arbeite nur im Variantenbranch, ändere keine Produktionsdateien, starte keine Pods und benchmarke nicht. Korrigiere nötige Restfehler, führe make validate/make drift aus und committe. Forschungsmodus: Wenn ein offizieller Upstream-/Paper-/CUDA-/SGLang-/Plugin-Ansatz oder eine Kombination plausibel besser ist, recherchiere die Primärquelle im Internet, dokumentiere URL, Datum, Nutzen und Risiko in docs/research-loop.md und beschreibe eine neue isolierte Variante mit eigenem Branch/Worktree. Übernehme sie nicht ungeprüft in Produktion; sie braucht dieselben Validate-, Start-, Health- und Benchmark-Gates."
  (cd "$worktree" && opencode run --dir "$worktree" --model local-litellm/qwen3.8-flash-next \
    --agent build --auto "$qwen_prompt") > "$run_dir/healing/$variant-qwen.log" 2>&1 || true
else
  echo "Qwen-Review verschoben: Produktionsdienst auf 8002 war nicht bereit."
fi
touch "$run_dir/healing/$variant.done"
echo "Reparaturlauf $variant beendet."
