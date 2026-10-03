#!/usr/bin/env bash
# Setzt das Grafana-Admin-Passwort neu (Podman-Secret + Zugangsdatei).
# Aufruf: ./scripts/reset-grafana-password.sh [neues-Passwort]
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${root}/lib/common.sh"
source "${root}/lib/secrets.sh"
pw="${1:-$(random_secret 12)}"
need_cmd podman 'Jetzt ausführen: make install'
podman secret rm grafana_admin_password >/dev/null 2>&1 || true
ensure_podman_secret grafana_admin_password "${pw}"
if [[ -f "${CREDENTIALS_FILE}" ]]; then
  awk -v pw="${pw}" '
    /^Grafana/ { printf "Grafana      http://127.0.0.1:3000   Benutzer admin   Passwort %s\n", pw; next }
    { print }' "${CREDENTIALS_FILE}" > "${CREDENTIALS_FILE}.tmp"
  mv -f "${CREDENTIALS_FILE}.tmp" "${CREDENTIALS_FILE}"
  chmod 0600 "${CREDENTIALS_FILE}"
fi
log 'Grafana-Passwort gesetzt.'
printf 'Jetzt anwenden: systemctl --user restart grafana.service\n'
