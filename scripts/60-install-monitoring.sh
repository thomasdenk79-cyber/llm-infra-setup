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
  systemctl --user is-active --quiet wiki-rebuild.timer || { printf 'FEHLT: Wiki-Rebuild-Timer laeuft nicht\n'; missing=1; }
  [[ "${missing}" == 0 ]] && printf 'OK: Beobachtung vollstaendig\n'
  exit "${missing}"
fi

need_cmd podman 'Jetzt ausführen: make install'
install -d -m 0755 "${HOME}/.local/share/llm-infra"/{loki,prometheus,grafana,alertmanager,open-webui,node-exporter/textfile,homepage/logs}
ensure_base_credentials
# Alloy liest das Journal des Rechners (loki.source.journal in
# config/monitoring/alloy.alloy). Fehlt der dauerhafte Journal-Ordner, lehnt
# Podman die fehlende Bind-Quelle ab und der Container laeuft nicht an.
if [[ ! -d /var/log/journal ]]; then
  printf 'HINWEIS: /var/log/journal fehlt - Alloy braucht dauerhafte Journale.\n' >&2
  printf '  sudo mkdir -p /var/log/journal\n  sudo systemd-tmpfiles --create --prefix /var/log/journal\n  sudo systemctl restart systemd-journald\n' >&2
fi
if [[ ! -f "${root}/quadlet/llm-gpu-exporter.container" ]]; then
  run "${root}/scripts/65-install-gpu-exporter.sh"
fi
# Grafana hinter dem oeffentlichen Zugang laeuft im Unterpfad /grafana/. Ohne
# root_url mit Pfad und serve_from_sub_path bricht die Seite ueber den Tunnel,
# weil Grafana seine Assets unter /public/ statt /grafana/public/ anbietet. Die
# Werte sind Rechnerangaben (haengen am Gateway-Namen) und liegen deshalb
# ausserhalb von Git; Vorlage ist config/grafana.env.example.
grafana_env="${SECRETS_DIR}/grafana.env"
if [[ ! -f "${grafana_env}" ]]; then
  dns="$(sed -n 's/^GATEWAY_DNS_NAME=//p' "${root}/config/gateway-proxy.env" 2>/dev/null | head -1 || true)"
  if [[ -n "${dns}" ]]; then
    wurzel="https://${dns}/grafana/"
  else
    wurzel="http://127.0.0.1:3000/grafana/"
  fi
  install -d -m 0700 "$(dirname -- "${grafana_env}")"
  printf '# GENERIERT von scripts/60-install-monitoring.sh - Vorlage: config/grafana.env.example\nGF_SERVER_ROOT_URL=%s\nGF_SERVER_SERVE_FROM_SUB_PATH=true\n' "${wurzel}" > "${grafana_env}"
  chmod 600 "${grafana_env}"
  log "Grafana-Adresse gesetzt: ${grafana_env} (${wurzel})"
fi
prune_legacy_units
install_units "${OBSERVABILITY_UNITS[@]}"
install_systemd_units "${HOME}/.config/systemd/user" llm-infra-collect-facts.service llm-infra-collect-facts.timer wiki-rebuild.service wiki-rebuild.timer
systemd_reload
start_units llm-observability.network loki.container prometheus.container grafana.container alloy.container dozzle.container llm-node-exporter.container llm-gpu-exporter.container homepage.container wiki.container
systemctl --user enable --now llm-infra-collect-facts.timer
systemctl --user enable --now wiki-rebuild.timer
run "${root}/scripts/collect-host-facts.sh" || log 'WARNUNG: erste Kennzahlensammlung fehlgeschlagen'
cat <<'NEXT'
Naechste Schritte
  1. Browser oeffnen:  http://127.0.0.1:3000   (Grafana, Passwort: ./scripts/show-credentials.sh)
  2. Targets pruefen:  http://127.0.0.1:9090/targets   (muss pennyroyal, node, gpu zeigen)
  3. Wenn etwas rot ist: ./scripts/doctor.sh
NEXT
