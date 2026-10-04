#!/usr/bin/env bash
# Parallele Qwen-Forschungsprüfung aller PLE-Varianten.
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
out="$root/state/research-audits/$stamp"
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
  (cd "$worktree" && opencode run --dir "$worktree" \
    --model local-litellm/qwen3.8-flash-next --agent build --auto \
    "$(cat "$out/$variant-prompt.txt")") > "$log" 2>&1 || true
}

audit_variant A "$root/../llm-infra-setup-turbo-upstream" &
audit_variant B "$root/../llm-infra-setup-variant-b" &
audit_variant C "$root/../llm-infra-setup-pennyroyal" &
audit_variant D "$root/../llm-infra-setup-variant-d" &
wait
echo "Forschungsprüfung abgeschlossen: $out"
