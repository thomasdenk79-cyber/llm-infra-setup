#!/usr/bin/env bash
# Parallele Qwen-Forschungsprüfung aller PLE-Varianten.
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
out="$root/state/research-audits/$stamp"

# Vorpruefung: ohne erreichbare Produktionsruntime (Pennyroyal 8001 oder Turbo 8002)
# und LiteLLM wuerden vier Agents nur stumm gegen eine tote API laufen.
_caller_litellm_port="${LITELLM_PORT:-}"
[[ -f "$root/config/host.env" ]] && source "$root/config/host.env"
LITELLM_PORT="${_caller_litellm_port:-${LITELLM_PORT:-4000}}"
if pgrep -f 'run-ple-variant-matrix\.sh' >/dev/null 2>&1 \
   || systemctl --user is-active --quiet ple-variant-matrix.service 2>/dev/null; then
  echo "Forschungspruefung verschoben: Matrixlauf haelt die GPU exklusiv."
  echo "Naechster Befehl: scripts/ple-research-audit.sh erneut aufrufen, wenn scripts/run-ple-variant-matrix.sh beendet ist."
  exit 0
fi
prod_ready=0
for candidate in 8001 8002; do
  curl -fsS --max-time 5 "http://127.0.0.1:${candidate}/health" >/dev/null 2>&1 && { prod_ready=1; break; }
done
if (( prod_ready == 0 )); then
  echo "Forschungspruefung verschoben: kein Produktionsdienst auf 8001/8002 erreichbar."
  echo "Naechster Befehl: ./scripts/doctor.sh"
  exit 1
fi
if ! curl -fsS --max-time 5 "http://127.0.0.1:${LITELLM_PORT}/health" >/dev/null 2>&1 \
   && ! curl -fsS --max-time 5 "http://127.0.0.1:${LITELLM_PORT}/health/liveness" >/dev/null 2>&1; then
  echo "Forschungspruefung verschoben: LiteLLM auf ${LITELLM_PORT} nicht erreichbar; Qwen haette kein Modell."
  echo "Naechster Befehl: ./scripts/doctor.sh"
  exit 1
fi

mkdir -p "$out"

audit_variant() {
  local variant="$1" worktree="$2"
  local report="$out/$variant.md" log="$out/$variant.log"
  cat > "$out/$variant-prompt.txt" <<EOF
Du bist der Forschungsprüfer für Variante $variant im Worktree $worktree.
Arbeite ausschließlich lesend am Code und an den Berichten; starte keine Pods,
ändere keine Produktions-Units und führe keinen Benchmark aus.

Prüfe gründlich:
1. alle bisherigen state/variant-runs/*- und state/benchmarks/-Daten im Hauptrepo,
2. Journaldaten und Fehlerbilder dieser Variante,
3. die aktuellen Commits und Unterschiede zum Produktionsstand,
4. bekannte Upstream-, CUDA-, SGLang-, io_uring-, Page-Cache- und Plugin-Ansätze.

Recherchiere im Internet mit Primärquellen, wenn Webzugriff verfügbar ist
(offizielle Repositories/Dokumentation/Papers bevorzugen). Suche auch nach
neuen Kombinationen, die als Variante E oder weitere Kandidaten sinnvoll wären.
Bewerte jede Idee nach erwarteter Tokenrate, Readiness-Risiko, Graph-Sicherheit,
SSD-PLE-Latenz und Implementierungsaufwand.

Schreibe den vollständigen Bericht nach $report mit:
- belegten Ursachen und Messwerten,
- Quellen-URL und Abrufdatum,
- Rangliste der nächsten Varianten/Kombinationen,
- konkreten Dateien und Parametern für einen isolierten Branch,
- klarer Empfehlung, was zuerst codiert werden sollte.
Keine erfundenen Messwerte. Wenn eine Quelle oder Messung fehlt, vermerken.
Committe ausschließlich den Forschungsbericht im Variantenworktree.
EOF
  (cd "$worktree" && timeout --signal=INT --kill-after=60s \
    "${OPENCODE_RESEARCH_MAX_SECONDS:-3600}" opencode run --dir "$worktree" \
    --model local-litellm/qwen3.8-flash-next --agent build --auto \
    "$(cat "$out/$variant-prompt.txt")") > "$log" 2>&1 || true
}

audit_variant A "$root/../llm-infra-setup-turbo-upstream" &
audit_variant B "$root/../llm-infra-setup-variant-b" &
audit_variant C "$root/../llm-infra-setup-pennyroyal" &
audit_variant D "$root/../llm-infra-setup-variant-d" &
wait
echo "Forschungsprüfung abgeschlossen: $out"
