#!/usr/bin/env bash
# Ersetzt die bei frueheren Versionen des Repos hart eingebauten
# Standard-Passwoerter durch Zufallswerte.
#
#   ./scripts/rotate-secrets.sh            alle Passwoerter ausser LiteLLM-Salt
#   ./scripts/rotate-secrets.sh --dry-run  nur anzeigen
#
# Wichtig: LITELLM_SALT_KEY wird absichtlich NICHT geaendert. LiteLLM
# verschluesselt damit bereits angelegte Virtual Keys; ein Wechsel macht sie
# unlesbar. Wer den Salt trotzdem tauschen will (z.B. alle Keys neu anlegen):
#   ./scripts/rotate-secrets.sh --also-salt   loescht danach alle virtuellen Keys!
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${root}/lib/common.sh"
source "${root}/lib/secrets.sh"
dry=0; also_salt=0
for a in "$@"; do
  case "$a" in
    --dry-run) dry=1 ;;
    --also-salt) also_salt=1 ;;
    *) echo 'usage: rotate-secrets.sh [--dry-run] [--also-salt]' >&2; exit 2 ;;
  esac
done
[[ -f "${SECRETS_DIR}/postgres.env" ]] || { echo 'Keine Zugangsdaten gefunden. Erst ./scripts/ensure-credentials.sh.' >&2; exit 1; }
# shellcheck disable=SC1090
source "${SECRETS_DIR}/postgres.env"
# shellcheck disable=SC1090
source "${SECRETS_DIR}/gateway.env"
[[ -f "${SECRETS_DIR}/open-webui.env" ]] && source "${SECRETS_DIR}/open-webui.env"

new_pg="$(random_secret 16)"
new_master="sk-$(random_secret 24)"
new_webui="$(random_secret 24)"
new_grafana="$(random_secret 12)"
salt="${LITELLM_SALT_KEY:-$(random_secret 24)}"
[[ "${also_salt}" == 1 ]] && salt="$(random_secret 24)"

echo 'Neue Zugangsdaten:'
printf '  PostgreSQL-Benutzer %s\n' "${POSTGRES_USER:-litellm}"
printf '  PostgreSQL-Passwort %s\n' "${new_pg}"
printf '  LiteLLM Master-Key  %s\n' "${new_master}"
printf '  Grafana admin        %s\n' "${new_grafana}"
printf '  Open WebUI Secret    %s\n' "${new_webui}"
printf '  LiteLLM Salt         %s\n' "$([[ "${also_salt}" == 1 ]] && echo 'neu (virtuelle Keys unbrauchbar!)' || echo 'unveraendert uebernommen')"
[[ "${dry}" == 1 ]] && { echo; echo '--dry-run: nichts geaendert.'; exit 0; }

read -r -p 'Diese Werte wirklich schreiben? J/N: ' reply
[[ "${reply}" == J || "${reply}" == j ]] || { echo 'abgebrochen'; exit 1; }

install -d -m 0700 "${SECRETS_DIR}/backup-$(date +%Y%m%dT%H%M%S)"
cp -a "${SECRETS_DIR}"/*.env "${SECRETS_DIR}/credentials.txt" "${SECRETS_DIR}/backup-$(date +%Y%m%dT%H%M%S)/" 2>/dev/null || true

umask 077
cat > "${SECRETS_DIR}/postgres.env" <<EOF
POSTGRES_DB=${POSTGRES_DB:-litellm}
POSTGRES_USER=${POSTGRES_USER:-litellm}
POSTGRES_PASSWORD=${new_pg}
EOF
cat > "${SECRETS_DIR}/gateway.env" <<EOF
LITELLM_MASTER_KEY=${new_master}
LITELLM_SALT_KEY=${salt}
DATABASE_URL=postgresql://${POSTGRES_USER:-litellm}:${new_pg}@litellm-postgres:5432/${POSTGRES_DB:-litellm}
EOF
cat > "${SECRETS_DIR}/open-webui.env" <<EOF
WEBUI_SECRET_KEY=${new_webui}
ENABLE_SIGNUP=true
ENABLE_OPENAI_API=true
OPENAI_API_BASE_URL=http://litellm:4000/v1
OPENAI_API_KEY=${new_master}
EOF
chmod 0600 "${SECRETS_DIR}"/*.env

printf '%s' "${new_master}" > "${SECRETS_DIR}/prometheus-litellm-token"
chmod 0600 "${SECRETS_DIR}/prometheus-litellm-token"

podman secret rm grafana_admin_password >/dev/null 2>&1 || true
ensure_podman_secret grafana_admin_password "${new_grafana}"

# Passwort in der laufenden Datenbank anpassen, sonst startet der Container mit
# neuer env-Datei gegen ein altes Passwort.
if [[ "$(podman ps --format '{{.Names}}' 2>/dev/null || true)" == *litellm-postgres* ]]; then
  podman exec -i litellm-postgres psql -U "${POSTGRES_USER:-litellm}" -d postgres \
    -c "ALTER USER \"${POSTGRES_USER:-litellm}\" WITH PASSWORD '${new_pg}';" >/dev/null
  log 'Datenbank-Passwort angepasst.'
fi

cat > "${CREDENTIALS_FILE}" <<EOF
# llm-infra Zugangsdaten (lokal, Modus 0600, niemals committen)
# Stand: $(date -Is)
Grafana      http://127.0.0.1:3000   Benutzer admin   Passwort ${new_grafana}
LiteLLM      http://127.0.0.1:4000   Master-Key ${new_master}
Open WebUI   http://127.0.0.1:3001   Anmeldung wie in den Browsereinstellungen
PostgreSQL   127.0.0.1:5432          Benutzer ${POSTGRES_USER:-litellm}  Passwort ${new_pg}  DB ${POSTGRES_DB:-litellm}
Wichtig:  LITELLM_SALT_KEY nach dem ersten Start NICHT mehr ändern, sonst sind
          gespeicherte Virtual-Keys in PostgreSQL nicht mehr lesbar.
EOF
chmod 0600 "${CREDENTIALS_FILE}"

# Grafana merkt sich sein Admin-Passwort in der eigenen Datenbank; das Secret
# wirkt nur beim allerersten Start. Deshalb zusaetzlich zuruecksetzen.
if [[ "$(podman ps --format '{{.Names}}' 2>/dev/null || true)" == *grafana* ]]; then
  podman exec grafana grafana cli admin reset-admin-password "${new_grafana}" >/dev/null 2>&1 \
    && log 'Grafana-Admin-Passwort gesetzt.' \
    || log 'WARNUNG: Grafana-Passwort nicht gesetzt. Manuell: podman exec grafana grafana cli admin reset-admin-password <pw>'
fi

echo 'Fertig. Dienste neu starten, damit die neuen Werte gelten:'
printf '  systemctl --user restart litellm-postgres.service litellm.service open-webui.service grafana.service\n'
printf 'Danach: ./scripts/doctor.sh\n'
