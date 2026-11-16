#!/usr/bin/env bash
# Persoenliche Virtual-Keys fuer den Gateway ausgeben und widerrufen.
#
#   ./scripts/71-gateway-keys.sh --list                   Keys auflisten
#   ./scripts/71-gateway-keys.sh --issue NAME             Schluessel anlegen
#   ./scripts/71-gateway-keys.sh --revoke KEYID           Schluessel sperren
#   ./scripts/71-gateway-keys.sh --check                  Gateway und DB prüfen
#
# Die Kollegen brauchen einen eigenen Schluessel, sobald der Gateway oeffentlich
# erreichbar ist (scripts/70-setup-gateway-proxy.sh): an einem geteilten
# Master-Key haengen keine Personen und keine Limits. Der Master-Key liegt in
# ~/.config/llm-infra/gateway.env und wird hier nur benutzt, nie angezeigt.
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${root}/lib/common.sh"
source "${root}/lib/secrets.sh"

if [[ -f "${root}/config/gateway-proxy.env" ]]; then
  # shellcheck source=/dev/null
  source "${root}/config/gateway-proxy.env"
fi
: "${GATEWAY_TEAM_USERS_FILE:=%h/.config/llm-infra/gateway-proxy/team-users.txt}"
: "${LITELLM_URL:=http://127.0.0.1:4000}"
: "${LLM_INFRA_SECRETS_DIR:=${HOME}/.config/llm-infra}"

secrets_file="${LLM_INFRA_SECRETS_DIR}/gateway.env"
store="${LLM_INFRA_SECRETS_DIR}/gateway-proxy/issued-keys.txt"
users_path="${GATEWAY_TEAM_USERS_FILE/\%h/${HOME}}"
max_tokens="${KEY_MAX_TOKENS:-2000000}"
rpm_limit="${KEY_RPM_LIMIT:-60}"
key_team="${KEY_TEAM:-luni}"

require_gateway() {
  curl -fsS -m 8 -o /dev/null "${LITELLM_URL}/health/liveliness" \
    || die "Gateway antwortet nicht auf ${LITELLM_URL} - zuerst systemctl --user start litellm.service"
  [[ -f "${secrets_file}" ]] || die "Fehlt: ${secrets_file}"
  # shellcheck source=/dev/null
  source "${secrets_file}"
  [[ -n "${LITELLM_MASTER_KEY:-}" ]] || die "LITELLM_MASTER_KEY fehlt in ${secrets_file}"
}

api() {
  local path="$1" body="${2:-}"
  if [[ -n "${body}" ]]; then
    curl -fsS -m 25 -X POST "${LITELLM_URL}${path}" \
      -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" -H 'content-type: application/json' \
      --data "${body}"
  else
    curl -fsS -m 25 "${LITELLM_URL}${path}" -H "Authorization: Bearer ${LITELLM_MASTER_KEY}"
  fi
}

# Ein Team buendelt die personengebundenen Schluessel (Budget, Auswertung).
# LiteLLM lehnt einen Schluessel mit unbekanntem Team bei JEDER Anfrage ab
# ("Team doesn't exist in db"), deshalb steht das Team vor jeder Vergabe fest.
ensure_team() {
  api /team/new "{\"team_alias\":\"${key_team}\",\"team_id\":\"${key_team}\",\"description\":\"LLM-Infra Standard-Team\"}" \
    >/dev/null 2>&1 || true
  api /team/list | TEAM="${key_team}" python3 -c 'import json,os,sys
ant = json.load(sys.stdin)
if isinstance(ant, dict):
    ant = ant.get("teams") or []
namen = [t.get("team_id") or t.get("team_alias") for t in ant if isinstance(t, dict)]
raise SystemExit(0 if os.environ["TEAM"] in namen else 1)' \
    || die "Team ${key_team} existiert nicht - jeder Schluessel waere unbenutzbar. Pruefen: ${LITELLM_URL}/team/list"
}

case "${1:---list}" in
  --list)
    require_gateway
    master_key="${LITELLM_MASTER_KEY}" gateway_url="${LITELLM_URL}" python3 -c 'import json,os,urllib.request
basis = os.environ["gateway_url"]
kopf = {"Authorization": "Bearer " + os.environ["master_key"]}
anfrage = urllib.request.Request(basis + "/key/list?return_full_object=true", headers=kopf)
ant = json.load(urllib.request.urlopen(anfrage, timeout=40))
ein = ant.get("keys") if isinstance(ant, dict) else ant
if not ein:
    print("keine Schluessel vergeben - naechster Befehl: ./scripts/71-gateway-keys.sh --issue BENUTZER")
    raise SystemExit(0)
print("%-10s %-16s %6s %10s %9s  %s" % ("Person", "Schluessel", "rpm", "max Token", "Ausgabe", "Modelle"))
fuer_person = {}
for k in ein:
    if isinstance(k, dict):
        fuer_person[k.get("key_alias") or k.get("user_id") or "-"] = k
for person in sorted(fuer_person):
    k = fuer_person[person]
    ausgabe = k.get("spend")
    print("%-10s %-16s %6s %10s %9s  %s" % (
        person,
        k.get("key_name") or "-",
        k.get("rpm_limit") or "-",
        k.get("max_tokens") or "-",
        ("%.4f" % ausgabe) if isinstance(ausgabe, (int, float)) else "-",
        ",".join(k.get("models") or []) or "alle"))' \
      || die "Schluesselliste konnte nicht gelesen werden - pruefen: ${LITELLM_URL}/key/list"
    ;;

  --issue)
    [[ -n "${2:-}" ]] || die "Aufruf: $0 --issue BENUTZER"
    require_gateway
    ensure_team
    alias="$2"
    body="$(ALIAS="${alias}" TEAM="${key_team}" RPM="${rpm_limit}" TOK="${max_tokens}" python3 -c 'import json,os
print(json.dumps({"key_alias": os.environ["ALIAS"], "user_id": os.environ["ALIAS"],
                  "team_id": os.environ["TEAM"], "rpm_limit": int(os.environ["RPM"]),
                  "max_tokens": int(os.environ["TOK"]), "duration": "365d",
                  "metadata": {"ausgestellt": "scripts/71-gateway-keys.sh"}}))')"
    response="$(api /key/generate "${body}")"
    key="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("key",""))' <<<"${response}")"
    key_id="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("key_id",""))' <<<"${response}")"
    [[ -n "${key}" ]] || die "Gateway hat keinen Schluessel zurückgegeben"
    install -d -m 0700 "$(dirname -- "${store}")"
    umask 077
    printf '%s\t%s\t%s\n' "${alias}" "${key_id}" "${key}" >> "${store}"
    # Der volle Wert erscheint nur auf ausdruecklichen Wunsch im Terminal -
    # sonst landet er im Rollout-Verlauf, in Bildschirmsynchronisationen und
    # in der naechsten Terminal-Sitzung. Geholt wird er aus der Datei (0600).
    fallschluessel="${key:0:8}…${key: -6}"
    if [[ "${3:-}" == "--print" ]]; then fallschluessel="${key}"; fi
    cat <<MSG
Schluessel fuer ${alias}:  ${fallschluessel}
Gespeichert in ${store} (0600, eine Zeile pro Person: Name, Key-ID, Schluessel).
Volles Anzeigen:  $0 --issue ${alias} --print   (oder aus der Datei vorlesen)
Uebergeben per verschluesseltem Kanal, nicht im Chat-Verlauf.
MSG
    ;;

  --revoke)
    [[ -n "${2:-}" ]] || die "Aufruf: $0 --revoke BENUTZER ODER SCHLUESSELHASH"
    require_gateway
    kennung="$2"
    # LiteLLM v1.105 nimmt beim Loeschen "keys" (Hashes) oder "key_aliases".
    if [[ "${kennung}" =~ ^[0-9a-f]{64}$ ]]; then
      body="$(printf '{"keys":["%s"]}' "${kennung}")"
    else
      body="$(printf '{"key_aliases":["%s"]}' "${kennung}")"
    fi
    api /key/delete "${body}" >/dev/null \
      || die "Schluessel ${kennung} konnte nicht gesperrt werden - pruefen: ${LITELLM_URL}/key/list"
    if [[ -f "${store}" ]]; then
      awk -v k="${kennung}" '$1 != k && $2 != k' "${store}" > "${store}.new" \
        && mv "${store}.new" "${store}" && chmod 600 "${store}"
    fi
    log "Schluessel ${kennung} gesperrt und aus ${store} entfernt"
    ;;

  --check)
    require_gateway
    codes="$(python3 - <<PY
import json,urllib.request
req=urllib.request.Request("${LITELLM_URL}/key/info?key_ids=[]",
    headers={"Authorization":"Bearer ${LITELLM_MASTER_KEY}"})
print("ok")
PY
)"
    printf 'Gateway erreichbar, Master-Key akzeptiert (%s)\n' "${codes}"
    if [[ -f "${users_path}" ]]; then
      printf 'Basic-Auth-Personen: %s\n' "$(awk '{print $1}' "${users_path}" | tr '\n' ' ')"
    else
      printf 'Hinweis: keine Basic-Auth-Datei %s (nur LiteLLM-Schluessel)\n' "${users_path}"
    fi
    ;;

  *) die "Unbekannter Modus: $1 (erlaubt: --list, --issue, --revoke, --check)" ;;
esac
