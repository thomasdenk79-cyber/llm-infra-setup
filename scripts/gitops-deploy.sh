#!/usr/bin/env bash
# Nativer GitOps-Weg: holen, pruefen, nur bei sauberem Stand ausrollen.
#
#   ./scripts/gitops-deploy.sh              ein Durchlauf (prueft origin/main)
#   ./scripts/gitops-deploy.sh --force      auch bei lokalen Aenderungen (zieht NUR ff)
#
# Regeln aus dem Masterprompt:
#   * main ist der Sollzustand
#   * kein automatischer Merge, keine Force-Resets
#   * bei lokalem Dreck: abbrechen und sichtbar melden
#   * Deployment nur fuer committeten Stand
#
# Der Waechter uebernimmt danach nichts: Aenderungen an der Runtime-Unit werden
# nur installiert, ein Neustart bleibt ein ausdruecklicher Schritt.
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${root}"
# shellcheck source=common.sh
source "${root}/lib/common.sh"
# shellcheck source=units.sh
source "${root}/lib/units.sh"
: "${GITOPS_REMOTE:=origin}"
: "${GITOPS_BRANCH:=main}"
force=0
[[ "${1:-}" == "--force" ]] && force=1

log 'GitOps-Lauf beginnt'
if ! git diff --quiet || [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  echo 'Lokale, nicht committete Aenderungen gefunden. Deployment wird abgebrochen.' >&2
  git --no-pager status --short
  echo 'Entweder committen (dann laeuft es beim naechsten Mal) oder mit --force arbeiten.' >&2
  [[ "${force}" == 1 ]] || exit 1
  echo '--force gesetzt: fahre fort, mache aber nur einen Fast-Forward.' >&2
fi

git fetch --quiet "${GITOPS_REMOTE}" || { echo 'fetch fehlgeschlagen (Netz?). Naechster Versuch spaeter.' >&2; exit 1; }
local_head="$(git rev-parse HEAD)"
remote_head="$(git rev-parse "${GITOPS_REMOTE}/${GITOPS_BRANCH}")"
if [[ "${local_head}" == "${remote_head}" ]]; then
  log 'keine Aenderung gegenueber '"${GITOPS_REMOTE}/${GITOPS_BRANCH}"
  exit 0
fi
log 'neuer Stand gefunden: '"${remote_head:0:10}"' (alt '"${local_head:0:10}"')'
git pull --ff-only "${GITOPS_REMOTE}" "${GITOPS_BRANCH}"

run ./scripts/validate.sh || { echo 'validate fehlgeschlagen - nichts ausgerollt.' >&2; exit 1; }
run ./scripts/check-drift.sh || echo 'Hinweis: Drift-Pruefung meldet Unterschiede (siehe oben).' >&2

# Nur die unkritischen Einheiten neu installieren; die Runtime bleibtlaufen.
prune_legacy_units
install_units "${OBSERVABILITY_UNITS[@]}"
install_units llm-inference.network litellm-postgres.container litellm.container open-webui.container
systemd_reload
start_units llm-observability.network loki.container prometheus.container grafana.container \
            alloy.container dozzle.container llm-node-exporter.container llm-gpu-exporter.container \
            homepage.container wiki.container litellm-postgres.container litellm.container open-webui.container
log 'GitOps-Lauf fertig. Runtime-Unit wurde nicht neu gestartet.'
printf 'Wenn die Runtime eine neue Unit braucht: ./scripts/apply-runtime-unit.sh\n'
