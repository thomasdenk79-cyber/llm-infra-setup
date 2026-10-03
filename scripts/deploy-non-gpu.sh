#!/usr/bin/env bash
# Startet alles, was OHNE GPU laeuft: Portal, Chat, Gateway, Datenbank,
# Beobachtung. Die GPU-Runtime wird nicht angefasst.
#
#   ./scripts/deploy-non-gpu.sh              installieren und starten
#   ./scripts/deploy-non-gpu.sh --check      nur pruefen
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${root}/lib/common.sh"
source "${root}/lib/units.sh"
source "${root}/lib/secrets.sh"
need_cmd podman 'Jetzt ausführen: make install'
if [[ "${1:-}" == "--check" ]]; then
  "${root}/scripts/60-install-monitoring.sh" --check
  exit $?
fi
run "${root}/scripts/63-install-postgres.sh"
run "${root}/scripts/60-install-gateway.sh"
run "${root}/scripts/60-install-open-webui.sh"
run "${root}/scripts/60-install-homepage.sh"
ensure_base_credentials
install -d -m 0755 "${HOME}/.local/share/llm-infra"/{postgres,open-webui,homepage/logs}
prune_legacy_units
install_units llm-inference.network litellm-postgres.container litellm.container open-webui.container
systemd_reload
start_units llm-inference.network litellm-postgres.container
sleep 3
start_units litellm.container open-webui.container
run "${root}/scripts/60-install-monitoring.sh"
cat <<'NEXT'
Fertig (ohne GPU).
  Portal        http://127.0.0.1:3002
  Chat          http://127.0.0.1:3001    ersten Account anlegen - der ist Admin
  Gateway       http://127.0.0.1:4000
  Dashboards    http://127.0.0.1:3000
Zugangsdaten: ./scripts/show-credentials.sh
Antworten erzeugt erst die GPU-Runtime: make deploy-ready
NEXT
