#!/usr/bin/env bash
# Wiki-Portal generieren: statischer Caddy-Server ueber WIKI_DIR/site/current auf :3003
# plus Rebuild-Timer. Das Wiki selbst lebt in ~/work/hermes-wiki (Git, MkDocs Material).
#   ./scripts/60-install-wiki.sh            Units generieren
#   ./scripts/60-install-wiki.sh --first    zusaendlich venv+Build vorbereiten
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${root}/lib/common.sh"
lock_feld() { awk -F': ' -v f="$1" '$1==f{gsub(/ /,"",$2); print $2; exit}' "${root}/versions.lock" 2>/dev/null || true; }
: "${WIKI_DIR:=${HOME}/work/hermes-wiki}"   # Rechnerprofil: config/host.env
wiki="${WIKI_DIR}"
wiki_h="${wiki/#"${HOME}"/%h}"
caddy_img="$(lock_feld caddy_wiki_image)"; [[ -n "${caddy_img}" ]] || caddy_img=docker.io/library/caddy:2-alpine
caddy_digest="$(lock_feld caddy_wiki_image_digest)"
[[ -n "${caddy_digest}" && "${caddy_img}" != *"@sha256:"* ]] && caddy_img="${caddy_img}@${caddy_digest}"
install -d -m 0755 "${root}/quadlet" "${root}/systemd" "${root}/config/wiki"

cat > "${root}/config/wiki/Caddyfile" <<'CADDY'
# GENERIERT von scripts/60-install-wiki.sh - dort ändern, nicht hier.
{
	admin off
	auto_https off
}
:8000 {
	encode gzip
	root * /srv/site/current
	file_server {
		index index.html
		hide "{path}" ".built-sha"
	}
	handle_errors {
		rewrite * /404.html
		file_server
	}
}
CADDY

cat > "${root}/quadlet/wiki.container" <<UNIT
# GENERIERT von scripts/60-install-wiki.sh - dort ändern, nicht hier.
[Unit]
Description=LLM Infrastructure Hermes-Wissens-Wiki (statischer Build)
After=llm-observability-network.service
Wants=llm-observability-network.service

[Container]
Image=${caddy_img}
ContainerName=llm-wiki
Network=llm-observability.network
PublishPort=127.0.0.1:3003:8000
HealthCmd=curl -sf http://127.0.0.1:8000/ -o /dev/null
HealthInterval=30s
HealthStartPeriod=10s
HealthRetries=3
Volume=${wiki_h}:/srv:Z,ro
Volume=@CONFIG_ROOT@/config/wiki/Caddyfile:/etc/caddy/Caddyfile:Z,ro

[Service]
Restart=on-failure
RestartSec=15

[Install]
WantedBy=default.target
UNIT

cat > "${root}/systemd/wiki-rebuild.service" <<'UNIT'
# GENERIERT von scripts/60-install-wiki.sh
[Unit]
Description=Hermes-Wiki neu bauen (nur bei neuen Commits)

[Service]
Type=oneshot
# Platzhalter: install_systemd_units in lib/units.sh ersetzt ihn durch die
# aktuelle Repo-Wurzel. Ein hier festgeschriebener Pfad ueberlebt keinen Umzug
# des Repos (vgl. systemd/llm-infra-collect-facts.service).
ExecStart=@CONFIG_ROOT@/scripts/wiki-rebuild.sh
UNIT

cat > "${root}/systemd/wiki-rebuild.timer" <<'UNIT'
# GENERIERT von scripts/60-install-wiki.sh
[Unit]
Description=Hermes-Wiki regelmaessig auf neue Commits pruefen

[Timer]
OnBootSec=2min
OnUnitActiveSec=30min
AccuracySec=1min

[Install]
WantedBy=timers.target
UNIT

if [[ "${1:-}" == "--first" ]]; then
  if [[ ! -d "${wiki}/docs" ]]; then
    log "Wiki-Inhalt fehlt: ${wiki}/docs — zuerst Seiten anlegen (SCHEMA.md im Repo beachten)."
  fi
  if [[ ! -x "${wiki}/.venv/bin/mkdocs" ]]; then
    log "Wiki-venv wird angelegt (einmalig, braucht Netz)..."
    python3 -m venv "${wiki}/.venv"
    "${wiki}/.venv/bin/pip" install -q --upgrade pip
    "${wiki}/.venv/bin/pip" install -q mkdocs-material
  fi
  "${root}/scripts/wiki-rebuild.sh" --force
fi
log 'Wiki-Portal generiert: quadlet/wiki.container (:3003) + wiki-rebuild.timer (30 min).'
