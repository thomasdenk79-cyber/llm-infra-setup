#!/usr/bin/env bash
# Wiki-Portal generieren: statischer Caddy-Server ueber hermes-wiki/site auf :3003
# plus Rebuild-Timer. Das Wiki selbst lebt in ~/work/hermes-wiki (Git, MkDocs Material).
#   ./scripts/60-install-wiki.sh            Units generieren
#   ./scripts/60-install-wiki.sh --first    zusaendlich venv+Build vorbereiten
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${root}/lib/common.sh"
wiki="${HOME}/work/hermes-wiki"
install -d -m 0755 "${root}/quadlet" "${root}/systemd" "${root}/config/wiki"

cat > "${root}/config/wiki/Caddyfile" <<'CADDY'
# GENERIERT von scripts/60-install-wiki.sh - dort ändern, nicht hier.
{
	admin off
	auto_https off
}
:8000 {
	encode gzip
	root * /srv
	file_server {
		index index.html
	}
	handle_errors {
		rewrite * /404.html
		file_server
	}
}
CADDY

sed "s#\${HOME}#%h#g; s#${wiki}#%h/work/hermes-wiki#g" > "${root}/quadlet/wiki.container" <<'UNIT'
# GENERIERT von scripts/60-install-wiki.sh - dort ändern, nicht hier.
[Unit]
Description=LLM Infrastructure Hermes-Wissens-Wiki (statischer Build)
After=llm-observability-network.service
Wants=llm-observability-network.service

[Container]
Image=docker.io/library/caddy:2-alpine
ContainerName=llm-wiki
Network=llm-observability.network
PublishPort=127.0.0.1:3003:8000
Volume=${HOME}/work/hermes-wiki/site:/srv:Z,ro
Volume=@CONFIG_ROOT@/config/wiki/Caddyfile:/etc/caddy/Caddyfile:Z,ro

[Service]
Restart=on-failure
RestartSec=15

[Install]
WantedBy=default.target
UNIT

cat > "${root}/systemd/wiki-rebuild.service" <<UNIT
# GENERIERT von scripts/60-install-wiki.sh
[Unit]
Description=Hermes-Wiki neu bauen (nur bei neuen Commits)

[Service]
Type=oneshot
ExecStart=${root}/scripts/wiki-rebuild.sh
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
