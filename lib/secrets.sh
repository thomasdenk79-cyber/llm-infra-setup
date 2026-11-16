#!/usr/bin/env bash
# Local credential handling. Nothing here is ever written into the repository:
# all files live in ${SECRETS_DIR} (default ~/.config/llm-infra) with mode 0600.

# shellcheck shell=bash
CREDENTIALS_FILE="${SECRETS_DIR}/credentials.txt"

credentials_banner() {
  cat >&2 <<EOF
Hinweis: Diese Zugänge wurden automatisch erzeugt und liegen nur lokal unter
         ${SECRETS_DIR} (Modus 0600, nicht in Git).
         Anzeigen jederzeit: ./scripts/show-credentials.sh
EOF
}

ensure_podman_secret() {
  # ensure_podman_secret <name> <value>
  local name="$1" value="$2"
  have podman || { log 'podman fehlt; Secret nicht angelegt.'; return 1; }
  if podman secret inspect "${name}" >/dev/null 2>&1; then
    log "Podman-Secret ${name} existiert bereits; unverändert."
    return 0
  fi
  printf '%s' "${value}" | podman secret create "${name}" - >/dev/null
  log "Podman-Secret ${name} angelegt."
}

env_wert() {
  # env_wert <datei> <SCHLUESSEL>  -> Wert ohne Anfuehrungszeichen, leer wenn fehlt.
  local file="$1" key="$2"
  [[ -f "${file}" ]] || return 0
  awk -F= -v k="${key}" '$1 == k { print substr($0, index($0, "=") + 1); exit }' "${file}"
}

# --- Chat-Umgebung (Open WebUI) ----------------------------------------------
# open-webui.env ist Generator-Ausgabe: die Einstellungen kommen aus diesem
# Skript, nicht aus dem Texteditor. Zwei Werte muessen stabil bleiben, weil sie
# bestehendes entwerten wuerden, und werden deshalb uebernommen:
#   WEBUI_SECRET_KEY   - sonst sind alle Sitzungscookies wertlos
#   OPENAI_API_KEY     - der Zugang zum Gateway, aus gateway.env erzeugt
# Das Administratorkonto ist NICHT Sache dieser Datei: es legt
# scripts/64-setup-open-webui-account.sh an und pflegt den Zugangswert in der
# Zugangsdatei. Zwei Schreibende fuer dieselbe Zeile waeren zwei Wahrheiten.
ensure_webui_env() {
  local file="${SECRETS_DIR}/open-webui.env" backup
  local secret gateway_key
  [[ -n "${LITELLM_MASTER_KEY:-}" ]] || die "LITELLM_MASTER_KEY fehlt - zuerst gateway.env anlegen (ensure_base_credentials)."

  secret="$(env_wert "${file}" WEBUI_SECRET_KEY)"
  [[ -n "${secret}" ]] || secret="$(random_secret 24)"
  gateway_key="$(env_wert "${file}" OPENAI_API_KEY)"
  [[ -n "${gateway_key}" ]] || gateway_key="${LITELLM_MASTER_KEY}"

  # Erst bauen, dann vergleichen: ein Lauf ohne Aenderung schreibt nichts und
  # legt keine Sicherung an (Idempotenz, Grundregel "Nichts zerstoeren").
  local tmp
  tmp="$(mktemp)"
  ( umask 077; cat > "${tmp}" <<EOF
# GENERIERT von lib/secrets.sh (ensure_webui_env) - dort aendern, nicht hier.
# Der Chat-Dienst liest diese Datei ueber EnvironmentFile in
# quadlet/open-webui.container.
WEBUI_SECRET_KEY=${secret}

# Registrierung aus. Sie ist nur fuer den allerersten Account gedacht und
# ueberlaeuft sonst den Rechner: jeder lokale Browser-Nutzer waere Admin.
# Das erste Konto darf sie trotzdem anlegen (upstream: auths.py signup, die
# erste Person wird ohne ui.enable_signup-Zwang zugelassen) - zustaendig dafuer
# ist scripts/64-setup-open-webui-account.sh.
ENABLE_SIGNUP=false
ENABLE_LOGIN_FORM=true

# Eigene Adresse, damit Links und Weiterleitungen im Browser nicht auf
# localhost:8080 (Container-Sicht) landen.
WEBUI_URL=http://127.0.0.1:3001

# Provider ist der Gateway dieses Stacks. Der Schluessel ist ein echter Wert aus
# gateway.env, nie ein Platzhalter; die Adresse ist die Container-Sicht des
# Netzes llm-inference.
ENABLE_OPENAI_API=true
OPENAI_API_BASE_URL=http://litellm:4000/v1
OPENAI_API_KEY=${gateway_key}

# Kein Ollama auf diesem Rechner: die Inferenz haengt am Gateway. Bleibt der
# Schluessel an, haengt jede Modellliste an einem Verbindungsversuch auf
# host.docker.internal:11434, den es hier nicht gibt.
ENABLE_OLLAMA_API=false

# Keine Update-Nagerei: das Bild ist ueber versions.lock gepinnt, und eine neue
# Version entscheidet der Betreiber. Ohne diesen Wert legt die App beim ersten
# Oeffnen einen modalen Hinweis ueber die Seite, der jeden Klick blockiert, bis
# er weggeklickt ist (gemessen 2026-11-16: /api/version/updates meldet
# v0.13.3 gegen das gepinnte v0.11.4).
ENABLE_VERSION_UPDATE_CHECK=false
EOF
  )
  install -d -m 0700 "${SECRETS_DIR}"
  if [[ -f "${file}" ]] && cmp -s "${tmp}" "${file}"; then
    rm -f "${tmp}"
    log 'Chat-Umgebung bereits in Generator-Fassung.'
  else
    if [[ -f "${file}" ]]; then
      backup="${file}.bak-$(date -u +%Y%m%dT%H%M%SZ)"
      cp -p "${file}" "${backup}"
      chmod 0600 "${backup}"
      log "Vorher-Sicherung der Chat-Umgebung: ${backup}"
    fi
    mv -f "${tmp}" "${file}"
    chmod 0600 "${file}"
    log 'Chat-Umgebung in Generator-Fassung gebracht.'
  fi
}

ensure_base_credentials() {
  install -d -m 0700 "${SECRETS_DIR}" \
    "${HOME}/.local/share/llm-infra/postgres" \
    "${HOME}/.local/share/llm-infra/open-webui" \
    "${HOME}/.local/share/llm-infra/homepage/logs"

  local postgres_env="${SECRETS_DIR}/postgres.env" created=0 pw master salt webui grafana_pw

  if [[ ! -f "${postgres_env}" ]]; then
    pw="$(random_secret 16)"
    write_secret_file "${postgres_env}" <<EOF
POSTGRES_DB=litellm
POSTGRES_USER=litellm
POSTGRES_PASSWORD=${pw}
EOF
    created=1
  fi
  # shellcheck disable=SC1090
  source "${postgres_env}"

  if [[ ! -f "${SECRETS_DIR}/gateway.env" ]]; then
    master="sk-$(random_secret 24)"
    salt="$(random_secret 24)"
    write_secret_file "${SECRETS_DIR}/gateway.env" <<EOF
LITELLM_MASTER_KEY=${master}
LITELLM_SALT_KEY=${salt}
DATABASE_URL=postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@litellm-postgres:5432/${POSTGRES_DB}
EOF
    created=1
  fi
  # shellcheck disable=SC1090
  source "${SECRETS_DIR}/gateway.env"

  # Chat-Zugang und -Einstellungen: idempotent, bei jedem Lauf in der
  # Generator-Fassung (Begruendung und Erhaltungsregeln oben bei ensure_webui_env).
  ensure_webui_env

  # Prometheus braucht den Master-Key fuer die Gateway-Metriken. Die Datei wird
  # bei jedem Lauf aus gateway.env erneuert, damit ein Passwortwechsel nicht
  # vergessen werden kann. Podman legt sonst einen Ordner am mount-Ziel an.
  token_file="${SECRETS_DIR}/prometheus-litellm-token"
  if [[ -d "${token_file}" ]]; then
    log 'Entferne versehentlich angelegten Ordner anstelle der Schluesseldatei.'
    rm -rf "${token_file}"
  fi
  if [[ -n "${LITELLM_MASTER_KEY:-}" ]]; then
    printf '%s' "${LITELLM_MASTER_KEY}" > "${token_file}"
    chmod 0600 "${token_file}"
  else
    log 'WARNUNG: LITELLM_MASTER_KEY unbekannt; Prometheus kann Gateway-Metriken nicht lesen.'
  fi

  if [[ ! -f "${CREDENTIALS_FILE}" ]]; then
    grafana_pw="$(random_secret 12)"
    ensure_podman_secret grafana_admin_password "${grafana_pw}" || true
    ( umask 077; cat > "${CREDENTIALS_FILE}" <<EOF
# llm-infra Zugangsdaten (lokal, Modus 0600, niemals committen)
Grafana      http://127.0.0.1:3000   Benutzer admin   Passwort ${grafana_pw}
LiteLLM      http://127.0.0.1:4000   Master-Key ${LITELLM_MASTER_KEY}
Open WebUI   http://127.0.0.1:3001   beim ersten Start ein eigenes Konto anlegen
PostgreSQL   127.0.0.1:5432          Benutzer ${POSTGRES_USER}  Passwort ${POSTGRES_PASSWORD}  DB ${POSTGRES_DB}
Wichtig:  LITELLM_SALT_KEY nach dem ersten Start NICHT mehr ändern, sonst sind
          gespeicherte Virtual-Keys in PostgreSQL nicht mehr lesbar.
EOF
    )
    chmod 0600 "${CREDENTIALS_FILE}"
    created=1
  else
    # The Podman secret can be lost (for example after `podman system reset`)
    # while the local credential file survives; recreate it from that file so
    # Grafana keeps starting with the same password.
    grafana_pw="$(awk '/Grafana/ { print $NF }' "${CREDENTIALS_FILE}" | tail -n 1)"
    if [[ -n "${grafana_pw}" ]]; then
      ensure_podman_secret grafana_admin_password "${grafana_pw}" || true
    else
      log 'WARNUNG: Podman-Secret grafana_admin_password fehlt und konnte aus der Zugangsdatei nicht gelesen werden.'
      log '        Jetzt ausführen: ./scripts/reset-grafana-password.sh <neues-Passwort>'
    fi
  fi

  if [[ "${created}" == 1 ]]; then
    log 'Lokale Zugangsdaten erzeugt.'
    credentials_banner
  fi
}

show_credentials() {
  if [[ ! -f "${CREDENTIALS_FILE}" ]]; then
    log 'Noch keine Zugangsdaten erzeugt. Ausführen: ./scripts/ensure-credentials.sh'
    return 1
  fi
  cat "${CREDENTIALS_FILE}"
}
