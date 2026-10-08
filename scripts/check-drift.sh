#!/usr/bin/env bash
# Prüft, ob die committeten Unit-Dateien genau das Ergebnis der Generatoren sind.
#
# Hintergrund: Mehrere Units werden von Skripten geschrieben. Aendert jemand eine
# Unit-Datei von Hand statt des Generators, driften Repository und Wirklichkeit
# auseinander - dieser Lauf faellt dann auf. Laeuft auch im CI.
#
#   ./scripts/check-drift.sh
#
# Das Skript startet keine Container und aendert nichts an installierten Units.
# Bei Abweichung wird der committete Stand wiederhergestellt und Exit 1 geliefert.
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${root}"
source "${root}/lib/common.sh"

if ! command -v podman >/dev/null 2>&1; then
  echo 'uebersprungen: podman nicht vorhanden (z. B. CI-Laufer).'
  exit 0
fi

tracked="$(git status --porcelain -- quadlet config/litellm.yaml 2>/dev/null)"
if [[ -n "${tracked}" ]]; then
  echo 'Im Arbeitsverzeichnis liegen ungecommittete Aenderungen an generierten Dateien.'
  echo 'Bitte zuerst committen oder mit git restore zuruecknehmen, dann erneut pruefen:'
  printf '%s\n' "${tracked}"
  exit 1
fi

run ./scripts/50-install-pennyroyal.sh
run ./scripts/60-install-gateway.sh
run ./scripts/60-install-open-webui.sh
run ./scripts/60-install-homepage.sh
run ./scripts/60-install-wiki.sh
run ./scripts/63-install-postgres.sh
run ./scripts/65-install-gpu-exporter.sh

if git diff --quiet -- quadlet config/litellm.yaml; then
  echo 'KEINE DRIFT: committete Units entsprechen exakt den Generatoren.'
  exit 0
fi

echo 'DRIFT GEFUNDEN - die Generatoren erzeugen etwas anderes als committet ist:'
git --no-pager diff -- quadlet config/litellm.yaml
echo
echo 'Entweder die Aenderung ist gewollt: git add quadlet config/litellm.yaml && git commit'
echo 'Oder sie war ein Versehen:          git restore quadlet config/litellm.yaml'
git restore -- quadlet config/litellm.yaml
exit 1
