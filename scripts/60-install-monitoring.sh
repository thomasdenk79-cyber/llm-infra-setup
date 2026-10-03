#!/usr/bin/env bash
# BeobachtungsEbene installieren: Metriken, Logs, Dashboards, Portal.
#
#   ./scripts/60-install-monitoring.sh            alles installieren und starten
#   ./scripts/60-install-monitoring.sh --check    nur pruefen, nichts aendern
#
# Was danach läuft (alle Ports nur auf 127.0.0.1):
#   Grafana    http://127.0.0.1:3000   Passworthinweis: ./scripts/show-credentials.sh
#   Prometheus http://127.0.0.1:9090
#   Loki       http://127.0.0.1:3100
#   Dozzle     http://127.0.0.1:8080
#   Homepage   http://127.0.0.1:3002
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${root}/lib/common.sh"
source "${root}/lib/units.sh"
source "${root}/lib/secrets.sh"
check_only=0
[[ "${1:-}" == "--check" ]] && check_only=1

if [[ "${check_only}" == 1 ]]; then
  missing=0
  for unit in "${OBSERVABILITY_UNITS[@]}"; do
    [[ -f "${UNIT_DIR}/${unit}" ]] || { printf 'FEHLT: %s ist nicht installiert\n' "${unit}"; missing=1; }
    unit_is_active "${unit}" || { printf 'FEHLT: %s laeuft nicht\n' "$(unit_service_name "${unit}")"; missing=1; }
  done
  systemctl --user is-active --quiet llm-infra-collect-facts.timer || { printf 'FEHLT: Kennzahlen-Timer laeuft nicht\n'; missing=1; }
  [[ "${missing}" == 0 ]] && printf 'OK: Beobachtung vollstaendig\n'
  exit "${missing}"
fi

need_cmd podman 'Jetzt ausführen: make install'
install -d -m 0755 "${HOME}/.local/share/llm-infra"/{loki,prometheus,grafana,open-webui,node-exporter/textfile,homepage/logs}
ensure_base_credentials
if [[ ! -f "${root}/quadlet/llm-gpu-exporter.container" ]]; then
  run "${root}/scripts/65-install-gpu-exporter.sh"
fi
prune_legacy_units
install_units "${OBSERVABILITY_UNITS[@]}"
install_systemd_units "${HOME}/.config/systemd/user" llm-infra-collect-facts.service llm-infra-collect-facts.timer
systemd_reload
start_units llm-observability.network loki.container prometheus.container grafana.container alloy.container dozzle.container llm-node-exporter.container llm-gpu-exporter.container homepage.container
systemctl --user enable --now llm-infra-collect-facts.timer
run "${root}/scripts/collect-host-facts.sh" || log 'WARNUNG: erste Kennzahlensammlung fehlgeschlagen'
cat <<'NEXT'
Naechste Schritte
  1. Browser oeffnen:  http://127.0.0.1:3000   (Grafana, Passwort: ./scripts/show-credentials.sh)
  2. Targets pruefen:  http://127.0.0.1:9090/targets   (muss pennyroyal, node, gpu zeigen)
  3. Wenn etwas rot ist: ./scripts/doctor.sh
NEXT
