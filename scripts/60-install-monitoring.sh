#!/usr/bin/env bash
# BeobachtungsEbene installieren: Metriken, Logs, Dashboards, Portal.
#
#   ./scripts/60-install-monitoring.sh            alles installieren und starten
#   ./scripts/60-install-monitoring.sh --check    nur pruefen, nichts aendern
#
# Was danach läuft (alle Ports nur auf 127.0.0.1):
#   Grafana    http://127.0.0.1:3000   Passworthinweis: ./scripts/show-credentials.sh
#              lokal ohne Anmeldung: https://grafana.localhost/grafana/ (scripts/74-setup-local-proxy.sh)
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
  systemctl --user is-active --quiet llm-stack-status.timer || { printf 'FEHLT: Stack-Status-Timer laeuft nicht (Status-Seiten bleiben leer)\n'; missing=1; }
  systemctl --user is-active --quiet wiki-rebuild.timer || { printf 'FEHLT: Wiki-Rebuild-Timer laeuft nicht\n'; missing=1; }
  # Anonymes Lesen und Einbettung sind ohne die vier Schluessel nicht erfuellet
  # (Abnahme: d-solo ohne Cookies 200, kein X-Frame-Options: deny).
  if [[ -f "${SECRETS_DIR}/grafana.env" ]]; then
    for schluessel in GF_AUTH_ANONYMOUS_ENABLED=true GF_AUTH_ANONYMOUS_ORG_ROLE=Viewer \
                      GF_AUTH_DISABLE_LOGIN_FORM=true GF_SECURITY_ALLOW_EMBEDDING=true; do
      grep -Fxq "${schluessel}" "${SECRETS_DIR}/grafana.env" \
        || { printf 'FEHLT: grafana.env enthaelt nicht %s\n' "${schluessel}"; missing=1; }
    done
  else
    printf 'FEHLT: %s fehlt (Vorlage: config/grafana.env.example)\n' "${SECRETS_DIR}/grafana.env"; missing=1
  fi
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
# Grafana laeuft im Unterpfad /grafana/ und ohne Anmeldung fuer den lokalen
# Zugang. Ohne root_url mit Pfad und serve_from_sub_path bricht die Seite
# sowohl ueber den lokalen Proxy (scripts/74-setup-local-proxy.sh) als auch
# ueber den Gateway-Tunnel, weil Grafana seine Assets dann unter /public/ statt
# /grafana/public/ anbietet. GF_SERVER_ROOT_URL zeigt auf den lokalen Proxy:
# https://grafana.localhost/grafana/ - damit liefert der Proxy die Seite, ohne
# dass Grafana auf die Gateway-Adresse umleitet und die absoluten Links dorthin
# zeigen. Der oeffentliche Zugang der Kollegen bleibt zusaetzlich durch
# Basic-Auth auf dem Gateway geschuetzt (401 ohne Zugang); die Einzelheiten
# stehen in docs/operations.md und docs/HANDOFF.md. Die Schluessel sind
# Rechnerangaben und liegen ausserhalb von Git; Vorlage ist
# config/grafana.env.example. Die Datei gehoert diesem Skript: bei Abweichung
# wird sie mit Zeitstempel-Sicherung neu geschrieben.
grafana_env="${SECRETS_DIR}/grafana.env"
grafana_env_geplant=$(cat <<'GRAFANA'
# GENERIERT von scripts/60-install-monitoring.sh - Vorlage: config/grafana.env.example
GF_SERVER_ROOT_URL=https://grafana.localhost/grafana/
GF_SERVER_SERVE_FROM_SUB_PATH=true
GF_AUTH_ANONYMOUS_ENABLED=true
GF_AUTH_ANONYMOUS_ORG_ROLE=Viewer
GF_AUTH_DISABLE_LOGIN_FORM=true
GF_SECURITY_ALLOW_EMBEDDING=true
GRAFANA
)
if [[ ! -f "${grafana_env}" ]] || ! cmp -s <(printf '%s\n' "${grafana_env_geplant}") "${grafana_env}"; then
  install -d -m 0700 "$(dirname -- "${grafana_env}")"
  if [[ -f "${grafana_env}" ]]; then
    cp -a "${grafana_env}" "${grafana_env}.bak.$(date -u +%Y%m%dT%H%M%SZ)"
    log "grafana.env wich ab - Sicherung daneben gelegt, neue Fassung geschrieben"
  fi
  printf '%s\n' "${grafana_env_geplant}" > "${grafana_env}"
  chmod 600 "${grafana_env}"
  log "Grafana-Adresse und anonymes Lesen gesetzt: ${grafana_env}"
fi
prune_legacy_units
# Incident-Agent (Status-Seiten, Vorfallsanalyse): gehuert zur Beobachtungsstufe,
# braucht aber ein laufendes Gateway fuer die Schluesselvergabe. Ist das Gateway
# unten, bleibt der Agent diese Runde aussen vor - die Seite bleibt bedienbar.
if [[ ! -f "${root}/quadlet/incident-agent.container" ]] || ! unit_is_active incident-agent.container; then
  if curl -s --max-time 3 "${LITELLM_URL:-http://127.0.0.1:4000}/health/liveliness" >/dev/null 2>&1; then
    run "${root}/scripts/80-setup-incident-agent.sh" \
      || log 'WARNUNG: Incident-Agent nicht eingerichtet - naechster Befehl: ./scripts/80-setup-incident-agent.sh'
  else
    log 'Hinweis: Gateway laeuft nicht - nach dem Start ./scripts/80-setup-incident-agent.sh ausfuehren, sonst bleibt die Vorfallsanalyse der Status-Seiten leer.'
  fi
fi
if [[ ! -f "${root}/quadlet/incident-agent.container" ]]; then
  OBSERVABILITY_UNITS=( "${OBSERVABILITY_UNITS[@]/incident-agent.container/}" )
fi
install_units "${OBSERVABILITY_UNITS[@]}"
install_systemd_units "${HOME}/.config/systemd/user" llm-infra-collect-facts.service llm-infra-collect-facts.timer llm-stack-status.service llm-stack-status.timer wiki-rebuild.service wiki-rebuild.timer
systemd_reload
start_units llm-observability.network loki.container prometheus.container grafana.container alloy.container dozzle.container llm-node-exporter.container llm-gpu-exporter.container homepage.container wiki.container llm-proxy.container
systemctl --user enable --now llm-infra-collect-facts.timer
systemctl --user enable --now llm-stack-status.timer
systemctl --user enable --now wiki-rebuild.timer
run "${root}/scripts/collect-host-facts.sh" || log 'WARNUNG: erste Kennzahlensammlung fehlgeschlagen'
run "${root}/scripts/collect-stack-status.sh" || log 'WARNUNG: erste Stack-Status-Sammlung fehlgeschlagen'
cat <<'NEXT'
Naechste Schritte
  1. Browser oeffnen:  https://grafana.localhost/grafana/   (lokal ohne Anmeldung;
     Verankerung der Proxy-CA: ./scripts/74-setup-local-proxy.sh --ca-import)
  2. Targets pruefen:  http://127.0.0.1:9090/targets   (muss pennyroyal, node, gpu zeigen)
  3. Wenn etwas rot ist: ./scripts/doctor.sh
NEXT
