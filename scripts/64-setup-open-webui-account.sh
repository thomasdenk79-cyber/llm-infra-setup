#!/usr/bin/env bash
# Erstes Konto in Open WebUI anlegen und den Zugangswert ablegen.
#
# Open WebUI macht das erste Konto zum Administrator. Ohne Konto haengt die
# Oberflaeche beim ersten Aufruf in /auth fest, und niemand kann die App pruefen.
# Der Zugangswert wird erzeugt, kommt in ~/.config/llm-infra/credentials.txt
# (0600) und wird nirgends ausgegeben - auch nicht in einem Fehlerfall.
#
# Idempotent: existiert bereits ein Konto, wird nur die Anmeldung gepueft.
# Aufruf: ./scripts/64-setup-open-webui-account.sh [--check] [--email ADRESSE]
set -euo pipefail
BASIS="${OPEN_WEBUI_URL:-http://127.0.0.1:3001}"
DATEN="${HOME}/.config/llm-infra"
KENNWORTDATEI="${DATEN}/credentials.txt"
EML="${OPEN_WEBUI_EMAIL:-}"
PRUEFEN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) PRUEFEN=1 ;;
    --email) EML="${2:-}"; shift ;;
    *) { echo "Unbekannte Option: $1 (Benutzung: $0 [--check] [--email ADRESSE])" >&2; exit 2; } ;;
  esac
  shift
done

anmelden() {
  local code
  code="$(curl -s -m 20 -o /dev/null -w '%{http_code}' -X POST "${BASIS}/api/v1/auths/signin" \
    -H 'content-type: application/json' \
    -d "{\"email\":\"${1}\",\"password\":\"${2}\"}" 2>/dev/null || echo 000)"
  [[ "$code" == "200" ]]
}

if [[ ! -s "$KENNWORTDATEI" ]]; then
  echo "Keine ${KENNWORTDATEI}. Weiter mit: ./scripts/ensure-credentials.sh" >&2
  exit 1
fi
BESTEHEND="$(sed -n 's/^Open WebUI.*passwort \([^ ]*\).*email \([^ ]*\).*/\1 \2/p' "$KENNWORTDATEI" | tail -1)"

if [[ -n "$BESTEHEND" ]]; then
  EML="${EML:-${BESTEHEND##* }}"
  PW="${BESTEHEND%% *}"
  if anmelden "$EML" "$PW"; then
    echo "Konto vorhanden und Anmeldung erfolgreich (${EML})."
    echo "weiter: ./scripts/healthcheck.sh"
    exit 0
  fi
  echo "Konto ist hinterlegt, Anmeldung abgelehnt. Naechster Befehl: $0 --check" >&2
  exit 1
fi

if [[ "$PRUEFEN" == "1" ]]; then
  echo "Kein Konto hinterlegt. Weiter mit: $0" >&2
  exit 1
fi

if [[ -z "$BESTEHEND" ]]; then
  if [[ ! -f "${DATEN}/open-webui.env" ]]; then
    echo "Keine ${DATEN}/open-webui.env. Weiter mit: ./scripts/60-install-open-webui.sh" >&2
    exit 1
  fi
  [[ -n "$EML" ]] || EML="betrieb@llm.lokal"
  PW="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)"
  code="$(curl -s -m 25 -o /dev/null -w '%{http_code}' -X POST "${BASIS}/api/v1/auths/signup" \
    -H 'content-type: application/json' \
    -d "{\"name\":\"Betrieb\",\"email\":\"${EML}\",\"password\":\"${PW}\"}" 2>/dev/null || echo 000)"
  if [[ "$code" != "200" ]]; then
    echo "Konto konnte nicht angelegt werden (HTTP ${code}). Laeuft Open WebUI? Naechster Befehl: systemctl --user status open-webui.service" >&2
    exit 1
  fi
  anmelden "$EML" "$PW" || { echo "Konto angelegt, Anmeldung fehlgeschlagen. Naechster Befehl: $0 --check" >&2; exit 1; }
  cp "$KENNWORTDATEI" "${KENNWORTDATEI}.bak.$(date -u +%Y%m%dT%H%M%SZ)"
  if grep -q '^Open WebUI' "$KENNWORTDATEI"; then
    sed -i 's|^Open WebUI.*|Open WebUI   '"${BASIS}"'   passwort '"${PW}"' email '"${EML}"' (Administrator, angelegt scripts/64-setup-open-webui-account.sh)|' "$KENNWORTDATEI"
  else
    printf 'Open WebUI   %s   passwort %s email %s (Administrator)\n' "$BASIS" "$PW" "$EML" >>"$KENNWORTDATEI"
  fi
  chmod 600 "$KENNWORTDATEI"
fi
echo "Konto angelegt und Anmeldung bestaetigt (${EML}); Zugangswert in ${KENNWORTDATEI} (0600)."
echo "weiter: ./scripts/healthcheck.sh"
