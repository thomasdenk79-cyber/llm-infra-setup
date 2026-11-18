#!/usr/bin/env bash
# Chat-Oberflaeche (Open WebUI) einrichten: Quadlet-Unit erzeugen und - auf
# ausdruecklichen Ruf - den Dienst in Betrieb nehmen.
#
#   ./scripts/60-install-open-webui.sh              nur die Unit-Datei schreiben
#   ./scripts/60-install-open-webui.sh --provision  dazu: Unit installieren, Dienst neu starten,
#                                                  Konto und Verbindungen sichern
#   ./scripts/60-install-open-webui.sh --check      nur pruefen, nichts aendern
#
# Der nackte Aufruf aendert nichts am laufenden Dienst, weil
# ./scripts/check-drift.sh (make drift) genau so aufruft und nichts starten will.
#
# Die Unit-Datei quadlet/open-webui.container wird hier geschrieben und traegt
# den Header "GENERIERT von". Aendern am Generator, nicht an der Datei.
#
# Warum ueberhaupt --provision: Open WebUI legt seine Einstellungen in der
# eigenen Datenbank webui.db ab, und Werte aus
# ~/.config/llm-infra/open-webui.env gelten nur fuer Schluessel, die dort noch
# fehlen (upstream: Config.seed_defaults ergaenzt ausschliesslich fehlende
# Zeilen). Ein Einstellungen-Austausch in der Datei wirkt auf eine bestehende
# Installation also nicht. Was garantiert dastehen muss, bekommt deshalb zwei
# Wege - beide idempotent:
#   Konto:        scripts/64-setup-open-webui-account.sh. Dieses Skript ruft es
#                 nur auf und meldet sich mit dem dort abgelegten Zugang an;
#                 Konto und Zugangszeile haben damit einen einzigen Schreibenden.
#   Verbindungen: Ollama aus, Gateway an, Standardmodell - ueber dieselben
#                 Endpunkte, die auch die Administrationsoberflaeche benutzt.
# Die Einstellungen sind keine Geschmacksfrage: dieser Rechner hat kein Ollama.
# Bleibt der Anbieter an, haengt jede Modellliste an einem Verbindungsversuch
# auf host.docker.internal:11434, und ohne Standardmodell steht der Chat ohne
# Auswahl da.
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${root}/lib/common.sh"
source "${root}/lib/units.sh"
source "${root}/lib/secrets.sh"
# shellcheck disable=SC1091  # Rechnerprofil, absichtlich ausserhalb von Git
[[ -f "${root}/config/host.env" ]] && source "${root}/config/host.env"

lock_feld() { awk -F': ' -v f="$1" '$1==f{gsub(/ /,"",$2); print $2; exit}' "${root}/versions.lock" 2>/dev/null || true; }
: "${OWUI_IMAGE:=$(lock_feld open_webui_image)}"
[[ -z "${OWUI_IMAGE}" ]] && OWUI_IMAGE=ghcr.io/open-webui/open-webui:v0.11.4
owui_digest="$(lock_feld open_webui_image_digest)"
[[ -n "${owui_digest}" && "${OWUI_IMAGE}" != *"@sha256:"* ]] && OWUI_IMAGE="${OWUI_IMAGE}@${owui_digest}"
chat_port=3001                                    # muss zu PublishPort passen
unit_name=open-webui.container
chat_base="http://127.0.0.1:${chat_port}"
env_file="${SECRETS_DIR}/open-webui.env"
gateway_container_url='http://litellm:4000/v1'    # Sicht des Chat-Containers
gateway_host_url="http://127.0.0.1:${LITELLM_PORT:-4000}/v1"   # Sicht des Rechners
standardmodell="${OPENWEBUI_DEFAULT_MODEL:-qwen3.8-flash-next}"
ADMIN_TOKEN=''

# ---------------------------------------------------------------- Einheiten ---
schreibe_unit() {
  install -d -m 0755 "${root}/quadlet"
  cat > "${root}/quadlet/open-webui.container" <<UNIT
# GENERIERT von scripts/60-install-open-webui.sh - dort ändern, nicht hier.
[Unit]
Description=Open WebUI chat and RAG interface
After=litellm.service
Wants=llm-inference-network.service litellm.service

[Container]
Image=${OWUI_IMAGE}
ContainerName=open-webui
Network=llm-inference.network
PublishPort=127.0.0.1:3001:8080
EnvironmentFile=%h/.config/llm-infra/open-webui.env
Volume=%h/.local/share/llm-infra/open-webui:/app/backend/data:Z,U

[Service]
Restart=on-failure
RestartSec=15

[Install]
WantedBy=default.target
UNIT
}

# ------------------------------------------------------------------- APIs ---
chat_get() {
  # chat_get <PFAD>  -> Koerper auf stdout (nur fuer Antworten ohne Geheimnis)
  local pfad="$1"
  local -a args=(-sS -m 30 -H 'accept: application/json' "${chat_base}${pfad}")
  if [[ -n "${ADMIN_TOKEN}" ]]; then
    args+=(-H "Authorization: Bearer ${ADMIN_TOKEN}")
  fi
  curl "${args[@]}"
}

chat_post() {
  # chat_post <PFAD> <JSON-KOERPER>  -> nur der HTTP-Code auf stdout. Die Koerper
  # enthalten Schluessel und werden verworfen, damit sie in keinem Protokoll
  # landen; der Request-Koerper laeuft ueber stdin, nicht ueber die Kommando-
  # zeile (sonst staende das Passwort im Prozessbaum).
  local pfad="$1" koerper="$2" ausgabe
  local -a args=(-sS -m 30 -o /dev/null -w '%{http_code} %{content_type}' -X POST
                 -H 'content-type: application/json' --data @- "${chat_base}${pfad}")
  if [[ -n "${ADMIN_TOKEN}" ]]; then
    args+=(-H "Authorization: Bearer ${ADMIN_TOKEN}")
  fi
  ausgabe="$(printf '%s' "${koerper}" | curl "${args[@]}")"
  # Die App gibt auf unbekannte Pfade das Single-Page-Geruest zurueck, und das
  # steht auch unter einem API-Pfad. Ohne diese Pruefung haette ein 200 auf
  # index.html als Erfolg gegolten, obwohl nichts gesetzt war.
  case "${ausgabe}" in
    '200 application/json'*) printf '200\n' ;;
    *text/html*)             printf 'kein-API\n' ;;
    *)                       printf '%s\n' "${ausgabe%% *}" ;;
  esac
}

chat_zugang() {
  # Liest den Chat-Zugang aus der Zugangsdatei, in der Form, die
  # scripts/64-setup-open-webui-account.sh schreibt ("passwort <pw> email
  # <mail>"). Ausgabe auf stdout: "<mail> <pw>". Der Wert wird nicht
  # protokolliert, nur weitergereicht.
  local zeile
  zeile="$(sed -n 's/^Open WebUI.*passwort \([^ ]*\).*email \([^ ]*\).*/\2 \1/p' \
            "${CREDENTIALS_FILE}" 2>/dev/null | tail -1)"
  [[ -n "${zeile}" ]] || return 1
  printf '%s' "${zeile}"
}

admin_anmelden() {
  # Meldet den Administrator an und fuellt ADMIN_TOKEN. Passwort und Token
  # werden nie ausgegeben.
  local mail pw code antwort zugang
  if ! zugang="$(chat_zugang)"; then
    log "Chat-Zugang fehlt oder steht in der alten Form in ${CREDENTIALS_FILE}."
    log '  Jetzt ausführen: ./scripts/64-setup-open-webui-account.sh'
    return 1
  fi
  mail="${zugang%% *}"; pw="${zugang##* }"
  antwort="$(MAIL="${mail}" PW="${pw}" python3 -c 'import json,os;print(json.dumps({"email":os.environ["MAIL"],"password":os.environ["PW"]}))' |
    curl -sS -m 20 -w '\n%{http_code}' -X POST -H 'content-type: application/json' --data @- "${chat_base}/api/v1/auths/signin")"
  code="${antwort##*$'\n'}"
  if [[ "${code}" != 200 ]]; then
    log "Anmeldung am Chat fehlgeschlagen (HTTP ${code}). Passwort in ${CREDENTIALS_FILE} oder Konto pruefen:"
    log "  journalctl --user -u open-webui.service -n 60 --no-pager"
    return 1
  fi
  ADMIN_TOKEN="$(printf '%s' "${antwort%$'\n'*}" |
    python3 -c 'import json,sys
try:
    print(json.load(sys.stdin).get("token", ""))
except Exception:
    print("")')"
  if [[ -z "${ADMIN_TOKEN}" ]]; then
    log 'Anmeldung brachte keinen Token - API-Oberflaeche nicht erreichbar.'
    return 1
  fi
  log 'Als Administrator angemeldet.'
}

warte_auf_gesundheit() {
  local ende=$(( SECONDS + 180 )) code
  while :; do
    code="$(curl -sS -m 5 -o /dev/null -w '%{http_code}' "${chat_base}/health" 2>/dev/null || true)"
    [[ "${code}" == 200 ]] && break
    if (( SECONDS >= ende )); then
      log 'Der Chat antwortet nicht auf /health. Naechster Schritt:'
      log '  journalctl --user -u open-webui.service -n 120 --no-pager'
      return 1
    fi
    sleep 3
  done
  log 'Chat antwortet auf /health.'
}

laufende_anfragen() {
  # Zaehlt Chat-Anfragen der letzten zwei Minuten im Journal. Ein Neustart des
  # Chat-Dienstes waerfe laufende Antworten weg (Grundregel 4).
  journalctl --user -u open-webui.service --since '-120 seconds' --no-pager 2>/dev/null |
    grep -cE 'POST /api/(chat|chat/completions|tasks)' || true
}

modell_ids() {
  # modell_ids <JSON>  -> Modellnamen, einer pro Zeile
  python3 -c 'import json,sys
try:
    daten = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if isinstance(daten, dict):
    daten = daten.get("data", [])
for m in daten:
    if isinstance(m, dict) and m.get("id"):
        print(m["id"])'
}

# ------------------------------------------------------------ Provisionierung ---
provisioniere() {
  need_cmd curl 'pacman -S --noconfirm curl'
  need_cmd python3 'pacman -S --noconfirm python'
  ensure_base_credentials

  schreibe_unit
  install_units "${unit_name}"
  systemd_reload

  if ! unit_is_active "${unit_name}"; then
    log 'Chat-Dienst ist nicht aktiv - wird gestartet.'
    start_units "${unit_name}"
  else
    # quadlet startet mit "podman run --replace": ein Neustart legt den
    # Container neu an, deshalb erreichen die Werte aus open-webui.env die App.
    local offen
    offen="$(laufende_anfragen)"
    if [[ "${offen}" != 0 && "${FORZIERT:-0}" != 1 ]]; then
      log "Letzte zwei Minuten: ${offen} Chat-Anfrage(n) im Journal. Der Neustart verwirft sie."
      log '  Warten und erneut: ./scripts/60-install-open-webui.sh --provision'
      log '  Bewusst ueberspringen: FORZIEREN=1 ./scripts/60-install-open-webui.sh --provision'
      return 1
    fi
    log 'Starte den Chat-Dienst neu (eigener, ausdruecklicher Schritt).'
    systemctl --user restart open-webui.service
  fi
  warte_auf_gesundheit
  # Das Konto vor den Verbindungen: ohne Konto gibt es keinen
  # Administrator-Token, und der ist fuer die Verbindungen noetig. Angelegt und
  # abgelegt wird das Konto ausschliesslich im Konto-Skript, hier wird nur
  # geprueft und, wenn es fehlt, gerufen.
  if ! "${root}/scripts/64-setup-open-webui-account.sh" --check >/dev/null 2>&1; then
    log 'Chat-Konto fehlt oder ist in alter Form - das Konto-Skript uebernimmt.'
    "${root}/scripts/64-setup-open-webui-account.sh" || {
      log 'Konto nicht bereit; die Meldung oben nennt den naechsten Befehl.'
      return 1
    }
  fi
  admin_anmelden
  setze_verbindungen
  pruefe_chat
}

setze_verbindungen() {
  # Die drei Punkte, die in der Datenbank der App wohnen und deshalb nicht mehr
  # aus der Env-Datei folgen. Jeder Schritt ist idempotent.
  local code koerper

  koerper="$(python3 -c 'import json
print(json.dumps({"ENABLE_OLLAMA_API": False, "OLLAMA_BASE_URLS": [], "OLLAMA_API_CONFIGS": {}}))')"
  code="$(chat_post /ollama/config/update "${koerper}" || true)"
  log "ollama Anbieter: deaktiviert (HTTP ${code})"

  koerper="$(BASE_URL="${gateway_container_url}" KEY="$(env_wert "${env_file}" OPENAI_API_KEY)" python3 -c 'import json,os
print(json.dumps({
    "ENABLE_OPENAI_API": True,
    "OPENAI_API_BASE_URLS": [os.environ["BASE_URL"]],
    "OPENAI_API_KEYS": [os.environ["KEY"]],
    "OPENAI_API_CONFIGS": {},
}))')"
  code="$(chat_post /openai/config/update "${koerper}" || true)"
  log "gateway Anbieter: ${gateway_container_url} (HTTP ${code}, Schluessel aus ${env_file})"

  koerper="$(MODELL="${standardmodell}" python3 -c 'import json,os
modell = os.environ["MODELL"] or None
print(json.dumps({
    "DEFAULT_MODELS": modell,
    "DEFAULT_PINNED_MODELS": modell,
    "MODEL_ORDER_LIST": None,
    "DEFAULT_MODEL_METADATA": None,
    "DEFAULT_MODEL_PARAMS": None,
}))')"
  code="$(chat_post /api/v1/configs/models "${koerper}" || true)"
  log "standardmodell: ${standardmodell} (HTTP ${code})"

  koerper="$(python3 -c 'import json
print(json.dumps({"config": {"ui.enable_signup": False}}))')"
  code="$(chat_post /api/v1/configs/import "${koerper}" || true)"
  log "registrierung: deaktiviert (HTTP ${code})"
}

pruefe_chat() {
  # Kleiner Ernstfall-Beleg: die App muss ein Modell des Gateways kennen.
  local app_modelle gateway_modelle gemeinsam
  app_modelle="$(chat_get /api/models | modell_ids | sort -u)"
  gateway_modelle="$(curl -sS -m 20 -H "Authorization: Bearer $(env_wert "${env_file}" OPENAI_API_KEY)" \
    "${gateway_host_url}/models" | modell_ids | sort -u)"
  gemeinsam="$(comm -12 <(printf '%s\n' "${app_modelle}") <(printf '%s\n' "${gateway_modelle}") | grep -c . || true)"
  if [[ "${gemeinsam}" -gt 0 ]]; then
    log "model check: OK (${gemeinsam} Modelle gemeinsam mit dem Gateway)"
  else
    log 'model check: FEHLER - die App kennt kein Modell des Gateways.'
    log '  Naechster Schritt: ./scripts/60-install-open-webui.sh --check'
    return 1
  fi
}

# ------------------------------------------------------------------- Pruefen ---
bericht() {
  # bericht <ok|DEFEKT> <text>
  printf '  [%-6s] %s\n' "$1" "$2"
  [[ "$1" == "ok" ]] || FEHLER=$(( FEHLER + 1 ))
}

pruefe() {
  local code anzeige
  FEHLER=0
  echo '--- Chat (Open WebUI) ---'

  # unit_exists will den Dienstatnamen (LoadState), unit_is_active kennt die
  # Umrechnung von der Quadlet-Datei - deshalb hier der Dienstatname.
  if unit_exists "${unit_name%.container}.service"; then
    if unit_is_active "${unit_name}"; then
      bericht ok "unit open-webui.service laeuft"
    else
      bericht DEFEKT 'unit ist nicht aktiv' '  systemctl --user start open-webui.service'
    fi
  else
    bericht DEFEKT 'unit ist nicht installiert' '  ./scripts/60-install-open-webui.sh --provision'
  fi

  if installed_unit_diff "${unit_name}" >/dev/null 2>&1; then
    bericht ok 'installierte Unit entspricht quadlet/open-webui.container'
  else
    bericht DEFEKT 'installierte Unit weicht von der Repo-Fassung ab' \
      '  systemctl --user daemon-reload && systemctl --user restart open-webui.service'
  fi

  code="$(curl -sS -m 8 -o /dev/null -w '%{http_code}' "${chat_base}/health" 2>/dev/null || true)"
  if [[ "${code}" == 200 ]]; then
    bericht ok 'health meldet true'
  else
    bericht DEFEKT "health antwortet nicht (HTTP ${code:-ohne})" '  journalctl --user -u open-webui.service -n 120 --no-pager'
  fi

  if [[ -f "${env_file}" ]]; then
    local fehlend=() schluessel
    for schluessel in WEBUI_SECRET_KEY OPENAI_API_KEY OPENAI_API_BASE_URL ENABLE_OLLAMA_API ENABLE_SIGNUP ENABLE_VERSION_UPDATE_CHECK; do
      if [[ -z "$(env_wert "${env_file}" "${schluessel}")" ]]; then fehlend+=("${schluessel}"); fi
    done
    if ((${#fehlend[@]} == 0)); then
      bericht ok "Umgebungsdatei vollstaendig (${env_file})"
    else
      bericht DEFEKT "Umgebungsdatei fehlen Schluessel: ${fehlend[*]}" '  ./scripts/60-install-open-webui.sh --provision'
    fi
  else
    bericht DEFEKT "Umgebungsdatei fehlt: ${env_file}" '  ./scripts/60-install-open-webui.sh --provision'
  fi

  if ! admin_anmelden; then
    bericht DEFEKT 'Administrator-Anmeldung misslang' '  ./scripts/64-setup-open-webui-account.sh'
  else
    bericht ok 'Administrator-Anmeldung gelingt (Zugang in credentials.txt)'

    anzeige="$(chat_get /ollama/config | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("keine Antwort"); raise SystemExit(0)
print("an" if d.get("ENABLE_OLLAMA_API") else "aus")' )"
    if [[ "${anzeige}" == "aus" ]]; then
      bericht ok 'ollama-Anbieter ist aus (es gibt keinen auf diesem Rechner)'
    else
      bericht DEFEKT 'ollama-Anbieter ist an, obwohl host.docker.internal:11434 nichts antwortet' \
        '  ./scripts/60-install-open-webui.sh --provision'
    fi

    anzeige="$(chat_get /api/v1/configs/namespace/ui | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("keine Antwort"); raise SystemExit(0)
print("an" if d.get("enable_signup") else "aus")' )"
    if [[ "${anzeige}" == "aus" ]]; then
      bericht ok 'Registrierung ist aus (kein beliebiger Admin durch Anmelden)'
    else
      bericht DEFEKT 'Registrierung ist an' '  ./scripts/60-install-open-webui.sh --provision'
    fi

    anzeige="$(chat_get /api/version/updates | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("keine Antwort"); raise SystemExit(0)
print("aus" if d.get("current") == d.get("latest") else "an")' )"
    if [[ "${anzeige}" == "aus" ]]; then
      bericht ok 'update-hinweis ist aus (Bild ist ueber versions.lock gepinnt)'
    else
      bericht DEFEKT 'update-hinweis steht an und legt beim Oeffnen ein modales Fenster ueber die Seite' \
        '  ./scripts/60-install-open-webui.sh --provision'
    fi

    local app_modelle gateway_modelle gemeinsam
    app_modelle="$(chat_get /api/models | modell_ids | sort -u)"
    gateway_modelle="$(curl -sS -m 20 -H "Authorization: Bearer $(env_wert "${env_file}" OPENAI_API_KEY)" \
      "${gateway_host_url}/models" 2>/dev/null | modell_ids | sort -u)"
    gemeinsam="$(comm -12 <(printf '%s\n' "${app_modelle}") <(printf '%s\n' "${gateway_modelle}") | grep -c . || true)"
    if [[ "${gemeinsam}" -gt 0 ]]; then
      bericht ok "modelliste gefuellt (${gemeinsam} Gateway-Modelle sichtbar)"
    else
      bericht DEFEKT 'modelliste der App enthaelt kein Gateway-Modell' \
        '  curl -s http://127.0.0.1:3001/api/models -H "Authorization: Bearer <token>"'
    fi

    if [[ -n "${standardmodell}" ]] && printf '%s\n' "${app_modelle}" | grep -qxF "${standardmodell}"; then
      bericht ok "standardmodell ${standardmodell} ist in der Auswahlliste"
    else
      bericht DEFEKT "standardmodell ${standardmodell:-ohne} fehlt in der Auswahlliste" \
        '  ./scripts/60-install-open-webui.sh --provision'
    fi
  fi

  echo
  if (( FEHLER == 0 )); then
    echo 'Chat-Pruefung: OK'
    echo '  Browser: http://127.0.0.1:3001'
    return 0
  fi
  echo "Chat-Pruefung: ${FEHLER} Punkt(e) zu beheben (Meldungen oben)."
  echo '  Meist genuegt: ./scripts/60-install-open-webui.sh --provision'
  return 1
}

# ------------------------------------------------------------------- Haupt ---
modus='unit'
for arg in "$@"; do
  case "${arg}" in
    --provision) modus='provision' ;;
    --check)     modus='check' ;;
    --forzieren) FORZIEREN=1 ;;
    -h|--help)   sed -n '2,30p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)           die "Unbekannte Option: ${arg}  (unterstuetzt: --provision, --check, --forzieren)" ;;
  esac
done

case "${modus}" in
  unit)
    schreibe_unit
    log "Open WebUI Quadlet erzeugt: localhost:${chat_port}."
    log 'In Betrieb nehmen (startet den Chat-Dienst neu): ./scripts/60-install-open-webui.sh --provision'
    ;;
  provision) provisioniere ;;
  check)     pruefe ;;
esac
