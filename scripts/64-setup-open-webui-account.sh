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
  local koerper
  koerper="$(mktemp)"
  ( umask 077; MAIL="$1" PW="$2" python3 -c 'import json,os;print(json.dumps({"email":os.environ["MAIL"],"password":os.environ["PW"]}))' > "${koerper}" )
  code="$(curl -s -m 20 -o /dev/null -w '%{http_code}' -X POST "${BASIS}/api/v1/auths/signin" \
    -H 'content-type: application/json' --data @"${koerper}" 2>/dev/null || echo 000)"
  rm -f "${koerper}"
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

# Fruehere Fassung des Generators schrieb die Open-WebUI-Zeile in einer anderen
# Form ("Benutzer <mail> Passwort <pw>"). Wer sie vorfindet, haelte das Konto
# fuer nicht vorhanden und das Anlegen schluegt fehl, weil das Konto laengst
# existiert. Uebernommen wird nur, was sich nachweislich anmelden kann, und nur
# in diesem Skript - es bleibt der einzige Schreibende der Zeile. Mit --check
# passiert nichts an der Datei, die Meldung nennt nur den Weg.
if grep -q '^Open WebUI' "$KENNWORTDATEI"; then
  ALT="$(sed -n 's/^Open WebUI.*Benutzer \([^ ]*\).*Passwort \([^ ]*\).*/\2 \1/p' "$KENNWORTDATEI" | tail -1)"
  if [[ -n "$ALT" ]]; then
    A_PW="${ALT%% *}"; A_EML="${ALT##* }"
    if [[ "$PRUEFEN" == "1" ]]; then
      echo "Zugangszeile steht in der alten Form. Weiter mit: $0" >&2
      exit 1
    fi
    anmelden "$A_EML" "$A_PW" || { echo "Alte Zugangszeile vorhanden, Anmeldung damit abgelehnt. Naechster Befehl: $0 --check" >&2; exit 1; }
    cp "$KENNWORTDATEI" "${KENNWORTDATEI}.bak.$(date -u +%Y%m%dT%H%M%SZ)"
    sed -i 's|^Open WebUI.*|Open WebUI   '"${BASIS}"'   passwort '"${A_PW}"' email '"${A_EML}"' (Administrator, uebernommen scripts/64-setup-open-webui-account.sh)|' "$KENNWORTDATEI"
    chmod 600 "$KENNWORTDATEI"
    echo "Zugangszeile in die einheitliche Form gebracht (${A_EML}); Anmeldung bestaetigt."
    echo "weiter: ./scripts/healthcheck.sh"
    exit 0
  fi
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
  local koerper2
  koerper2="$(mktemp)"
  ( umask 077; EMLV="$EML" PWV="$PW" python3 -c 'import json,os;print(json.dumps({"name":"Betrieb","email":os.environ["EMLV"],"password":os.environ["PWV"]}))' > "${koerper2}" )
  code="$(curl -s -m 25 -o /dev/null -w '%{http_code}' -X POST "${BASIS}/api/v1/auths/signup" \
    -H 'content-type: application/json' --data @"${koerper2}" 2>/dev/null || echo 000)"
  rm -f "${koerper2}"
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
