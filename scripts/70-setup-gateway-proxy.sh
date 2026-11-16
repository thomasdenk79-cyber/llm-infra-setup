#!/usr/bin/env bash
# Oeffentlicher Zugang fuer die Kollegen: Reverse-Tunnel zum Gateway-Rechner
# und der Caddy auf diesem Rechner, der fuer beide Seiten TLS an 443 liefert.
#
#   cp config/gateway-proxy.env.example config/gateway-proxy.env   # Ziel eintragen
#   ./scripts/70-setup-gateway-proxy.sh --check     pruefen, nichts aendern
#   ./scripts/70-setup-gateway-proxy.sh --status    Kurzbild des Ist-Zustands
#   ./scripts/70-setup-gateway-proxy.sh --hash NAME Basic-Auth-Hash erzeugen
#   ./scripts/70-setup-gateway-proxy.sh             alles einrichten
#
# Was dabei entsteht:
#   1. ein eigener SSH-Schluessel nur fuer den Tunnel (kein Login-Schluessel),
#   2. auf dem Gateway eine authorized_keys-Zeile, die genau diese Loopback-Ports
#      erlaubt (permitlisten) - alles andere bleibt verriegelt,
#   3. die Benutzer-Unit llm-reverse-tunnel.service, die die drei Dienste auf
#      127.0.0.1 des Gateway-Rechners spiegelt,
#   4. das Caddyfile des Gateway-Rechners aus config/gateway/Caddyfile.template.
#
# Der oeffentliche Port ist ausschliesslich 443 (Caddy). Der Tunnel selbst
# bindet nirgends auf 0.0.0.0: LiteLLM ist ohne persoenlichen Virtual-Key nicht
# nutzbar (./scripts/71-gateway-keys.sh), Grafana und Homepage zusaetzlich mit
# Basic-Auth pro Person.
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${root}/lib/common.sh"
source "${root}/lib/units.sh"

# Reine Benutzer-Units (kein Quadlet) liegen in systemd/user, nicht im
# Quadlet-Verzeichnis containers/systemd.
SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"

if [[ -f "${root}/config/gateway-proxy.env" ]]; then
  # shellcheck source=/dev/null
  source "${root}/config/gateway-proxy.env"
fi
: "${GATEWAY_DNS_NAME:=}"
: "${GATEWAY_PUBLIC_IP:=}"
: "${GATEWAY_VM_USER:=azureuser}"
: "${GATEWAY_VM_SSH_PORT:=22}"
: "${GATEWAY_SSH_KEY:=%h/.ssh/llm_gateway_tunnel_ed25519}"
: "${GATEWAY_BOOTSTRAP_KEY:=%h/.ssh/id_ed25519}"
: "${GATEWAY_LITELLM_PORT:=4000}"
: "${GATEWAY_GRAFANA_PORT:=3000}"
: "${GATEWAY_HOMEPAGE_PORT:=3002}"
: "${GATEWAY_ADMIN_FORWARD_PORT:=0}"
: "${GATEWAY_TLS_MODE:=internal}"
: "${GATEWAY_LE_EMAIL:=}"
: "${GATEWAY_TEAM_USERS_FILE:=%h/.config/llm-infra/gateway-proxy/team-users.txt}"
: "${GATEWAY_CADDY_FILE:=/etc/caddy/Caddyfile}"

key_path="${GATEWAY_SSH_KEY/\%h/${HOME}}"
bootstrap_path="${GATEWAY_BOOTSTRAP_KEY/\%h/${HOME}}"
users_path="${GATEWAY_TEAM_USERS_FILE/\%h/${HOME}}"
remote="${GATEWAY_VM_USER}@${GATEWAY_DNS_NAME:-$GATEWAY_PUBLIC_IP}"
known_hosts="${HOME}/.local/share/llm-infra/ssh/gateway-known_hosts"
unit_target="${SYSTEMD_USER_DIR}/llm-reverse-tunnel.service"

vmmit() {
  local schlussel="$1"; shift
  ssh -i "${schlussel}" -p "${GATEWAY_VM_SSH_PORT}" -o BatchMode=yes \
      -o ConnectTimeout=12 -o StrictHostKeyChecking=accept-new \
      -o UserKnownHostsFile="${known_hosts}" "${remote}" "$@"
}

# Welcher Schluessel gerade gilt: der Tunnel-Schluessel, und solange er auf dem
# Gateway noch nicht autorisiert ist, der Anmeldeschluessel fuer die Erstversorgung.
geloeschter_schluessel=""
resolve_key() {
  [[ -n "${geloeschter_schluessel}" ]] && return 0
  if [[ -f "${key_path}" ]] && vmmit "${key_path}" true </dev/null >/dev/null 2>&1; then
    geloeschter_schluessel="${key_path}"; return 0
  fi
  if [[ -f "${bootstrap_path}" ]] && vmmit "${bootstrap_path}" true </dev/null >/dev/null 2>&1; then
    geloeschter_schluessel="${bootstrap_path}"; return 0
  fi
  return 1
}

vm() {
  resolve_key || die "Kein Schluessel wird vom Gateway akzeptiert: ${key_path} nicht autorisiert${bootstrap_path:+, Anmeldeschluessel ${bootstrap_path} fehlt oder abgelehnt}"
  vmmit "${geloeschter_schluessel}" "$@"
}

require_target() {
  [[ -n "${GATEWAY_DNS_NAME}${GATEWAY_PUBLIC_IP}" ]] || {
    cat >&2 <<MSG
ABBRUCH: Kein Gateway-Rechner konfiguriert.
  cp config/gateway-proxy.env.example config/gateway-proxy.env
  nano config/gateway-proxy.env      # GATEWAY_DNS_NAME und GATEWAY_PUBLIC_IP eintragen
MSG
    exit 1
  }
}

# --- Bausteine -------------------------------------------------------------
forwards() {
  local -a f=()
  f+=("-R" "127.0.0.1:${GATEWAY_LITELLM_PORT}:localhost:${GATEWAY_LITELLM_PORT}")
  f+=("-R" "127.0.0.1:${GATEWAY_GRAFANA_PORT}:localhost:${GATEWAY_GRAFANA_PORT}")
  f+=("-R" "127.0.0.1:${GATEWAY_HOMEPAGE_PORT}:localhost:${GATEWAY_HOMEPAGE_PORT}")
  if [[ "${GATEWAY_ADMIN_FORWARD_PORT}" != "0" ]]; then
    f+=("-R" "127.0.0.1:${GATEWAY_ADMIN_FORWARD_PORT}:localhost:22")
  fi
  printf '%s ' "${f[@]}"
}

ensure_key() {
  if [[ ! -f "${key_path}" ]]; then
    install -d -m 0700 "$(dirname -- "${key_path}")"
    ssh-keygen -q -t ed25519 -N '' -f "${key_path}" \
      -C "llm-gateway-tunnel@$(hostname)"
    log "neuer Schluessel nur fuer den Tunnel: ${key_path}"
  fi
}

permitlisten_options() {
  local -a p=()
  for port in "${GATEWAY_LITELLM_PORT}" "${GATEWAY_GRAFANA_PORT}" "${GATEWAY_HOMEPAGE_PORT}"; do
    p+=("permitlisten=\"127.0.0.1:${port}\"")
  done
  printf 'restrict,port-forwarding,no-agent-forwarding,no-X11-forwarding,%s' "$(IFS=,; echo "${p[*]}")"
}

# authorized_keys-Zeile fuer unseren Schluessel setzen: gleiche Comment-Zeile
# wird ersetzt, sonst angehaengt. Vorher immer Sicherung auf dem Gateway.
# Der erste Lauf kann den Tunnel-Schluessel selbst nicht benutzen (er ist dann
# noch nicht autorisiert) - fuer diese Erstversorgung dient der Anmeldeschluessel.
install_authorized_key() {
  local pubkey options comment existing
  pubkey="$(cat "${key_path}.pub")"
  options="$(permitlisten_options)"
  comment="$(awk '{print $3}' <<<"${pubkey}")"
  resolve_key || die "Kein Schluessel wird vom Gateway akzeptiert - ${key_path} und ${bootstrap_path} sind beide unbrauchbar"
  if [[ "${geloeschter_schluessel}" == "${bootstrap_path}" ]]; then
    log "Erstversorgung ueber Anmeldeschluessel ${bootstrap_path##*/}"
  fi
  existing="$(vm "grep -F ' ${comment}\$' ~/.ssh/authorized_keys || true")"
  if [[ -n "${existing}" && "${existing}" == "${options} ${pubkey}" ]]; then
    log "authorized_keys auf dem Gateway passt bereits"
    return 0
  fi
  vm "cp -a ~/.ssh/authorized_keys ~/.ssh/authorized_keys.bak.\$(date -u +%Y%m%dT%H%M%SZ) 2>/dev/null || true
      grep -vF ' ${comment}\$' ~/.ssh/authorized_keys > ~/.ssh/authorized_keys.new || true
      printf '%s %s\n' '${options}' '${pubkey}' >> ~/.ssh/authorized_keys.new
      mv ~/.ssh/authorized_keys.new ~/.ssh/authorized_keys
      chmod 600 ~/.ssh/authorized_keys"
  geloeschter_schluessel=""
  log "authorized_keys auf dem Gateway gesetzt (Schluessel nur fuer die drei Loopback-Ports)"
}

render_caddyfile() {
  local tls addresses
  case "${GATEWAY_TLS_MODE}" in
    internal) tls="tls internal" ;;
    acme)     tls="tls" ;;
    custom)   tls="tls ${GATEWAY_TLS_CERT} ${GATEWAY_TLS_KEY}" ;;
    *) die "GATEWAY_TLS_MODE muss internal, acme oder custom sein" ;;
  esac
  if [[ -n "${GATEWAY_DNS_NAME}" && -n "${GATEWAY_PUBLIC_IP}" ]]; then
    addresses="https://${GATEWAY_DNS_NAME} https://${GATEWAY_PUBLIC_IP}"
  elif [[ -n "${GATEWAY_DNS_NAME}" ]]; then
    addresses="https://${GATEWAY_DNS_NAME}"
  else
    addresses="https://${GATEWAY_PUBLIC_IP}"
  fi
  local team=""
  [[ -f "${users_path}" ]] && team="$(awk 'NF && !gesehen[$1]++ {print}' "${users_path}")"
  sed -e "s#__SITE_ADDRESSES__#${addresses}#" \
      -e "s#__DEFAULT_SNI__#${GATEWAY_DNS_NAME:-${GATEWAY_PUBLIC_IP}}#" \
      -e "s#__TLS_BLOCK__#${tls}#" \
      -e "s#__LE_EMAIL__#${GATEWAY_LE_EMAIL:+email ${GATEWAY_LE_EMAIL}}#" \
      -e "s#__LITELLM_PORT__#${GATEWAY_LITELLM_PORT}#" \
      -e "s#__GRAFANA_PORT__#${GATEWAY_GRAFANA_PORT}#" \
      -e "s#__HOMEPAGE_PORT__#${GATEWAY_HOMEPAGE_PORT}#" \
      "${root}/config/gateway/Caddyfile.template" \
    | awk -v team="${team}" '{
        if ($0 ~ /^[[:space:]]*#/) { print; next }   # Kommentarzeilen nennen die Platzhalter nur
        while ((n = index($0, "__TEAM_USERS__")) > 0) {
          printf "%s%s%s\n", substr($0, 1, n - 1), team, substr($0, n + 14)
          next
        }
        print
      }'
}

# Basic-Auth-Hashes lassen sich nicht erraten: wenn die lokale Datei fehlt, aber
# auf dem Gateway schon ein Caddyfile mit basic_auth steht, werden die vorhandenen
# Hashes heruntergezogen, statt sie beim ersten Lauf zu verlieren.
adopt_team_users() {
  [[ -f "${users_path}" ]] && return 0
  local live
  live="$(vm "cat ${GATEWAY_CADDY_FILE} 2>/dev/null" || true)"
  [[ -z "${live}" ]] && { log "keine laufende Caddy-Konfiguration auf dem Gateway gefunden"; return 0; }
  install -d -m 0700 "$(dirname -- "${users_path}")"
  awk '/^[[:space:]]+[A-Za-z0-9_.@-]+ \$2[aby]\$/ {gsub(/^[[:space:]]+/,""); if (!gesehen[$1]++) print; fund=1} END {exit !fund}' <<<"${live}" \
    > "${users_path}" || true
  if [[ -s "${users_path}" ]]; then
    chmod 600 "${users_path}"
    log "Basic-Auth-Hashes vom Gateway uebernommen: ${users_path} ($(wc -l < "${users_path}") Personen)"
  fi
}

install_unit() {
  local rendered forwards_value
  install -d -m 0755 "${SYSTEMD_USER_DIR}"
  forwards_value="$(forwards)"
  rendered="$(sed -e "s#@CONFIG_ROOT@#${root}#g" \
                  -e "s#@SSH_KEY@#${key_path}#g" \
                  -e "s#@SSH_PORT@#${GATEWAY_VM_SSH_PORT}#g" \
                  -e "s#@FORWARDS@#${forwards_value}#g" \
                  -e "s#@REMOTE@#${remote}#g" \
                  "${SYSTEMD_SRC_DIR}/llm-reverse-tunnel.service")"
  if [[ -f "${unit_target}" && "$(grep -v '^#' "${unit_target}" | tr -d '[:space:]')" == "$(grep -v '^#' <<<"${rendered}" | tr -d '[:space:]')" ]]; then
    log "Tunnel-Unit ist aktuell"
    return 0
  fi
  install -m 0644 /dev/null "${unit_target}"
  printf '%s\n' "${rendered}" > "${unit_target}"
  systemd_reload
  log "Tunnel-Unit installiert: ${unit_target}"
}

# --- Modi ------------------------------------------------------------------
case "${1:---apply}" in
  --hash)
    [[ -n "${2:-}" ]] || die "Aufruf: $0 --hash BENUTZER"
    printf 'Passwort fuer %s: ' "$2"; read -rs password; echo
    if command -v htpasswd >/dev/null 2>&1; then
      hash="$(htpasswd -bnBC 14 "" "$2" | cut -d: -f2 | tr -d '\n')"
    elif python3 -c 'import bcrypt' 2>/dev/null; then
      hash="$(password="${password}" user="$2" python3 -c 'import bcrypt,os
print(bcrypt.hashpw(os.environ["password"].encode(), bcrypt.gensalt(14)).decode())')"
    else
      die "weder htpasswd noch das Python-Modul bcrypt vorhanden - bitte eines davon installieren (make install)"
    fi
    install -d -m 0700 "$(dirname -- "${users_path}")"
    grep -v "^$2 " "${users_path}" 2>/dev/null > "${users_path}.new" || true
    printf '%s %s\n' "$2" "${hash}" >> "${users_path}.new"
    mv "${users_path}.new" "${users_path}"; chmod 600 "${users_path}"
    log "Hash gespeichert in ${users_path}; mit $0 ausrollen"
    ;;

  --check)
    require_target
    rc=0
    [[ -f "${key_path}" ]] || { printf 'FEHLT: Tunnel-Schluessel %s\n' "${key_path}"; rc=1; }
    vm 'echo verbindung-ok' >/dev/null 2>&1 || { printf 'FEHLT: SSH zum Gateway (%s) nicht moeglich\n' "${remote}"; rc=1; }
    systemctl --user is-active --quiet llm-reverse-tunnel.service \
      || { printf 'FEHLT: llm-reverse-tunnel.service laeuft nicht\n'; rc=1; }
    if [[ "${rc}" == 0 ]]; then
      for port in "${GATEWAY_LITELLM_PORT}" "${GATEWAY_GRAFANA_PORT}" "${GATEWAY_HOMEPAGE_PORT}"; do
        vm "ss -tln 2>/dev/null | grep -q '127.0.0.1:${port} '" \
          || printf 'FEHLT: Gateway hoert nicht auf 127.0.0.1:%s (Tunnel steht nicht)\n' "${port}"
      done
      code="$(curl -sk -m 15 -o /dev/null -w '%{http_code}' \
              --resolve "${GATEWAY_DNS_NAME}:443:${GATEWAY_PUBLIC_IP}" \
              "https://${GATEWAY_DNS_NAME}/health/liveliness" || echo 000)"
      [[ "${code}" == "200" ]] || printf 'FEHLT: oeffentlicher Pfad liefert /health/liveliness nicht 200 (sondern %s)\n' "${code}"
    fi
    [[ "${rc}" == 0 ]] && printf 'OK: oeffentlicher Zugang richtet sich wie vereinbart\n'
    exit "${rc}"
    ;;

  --status)
    require_target
    printf 'Gateway      %s (IP %s)\n' "${GATEWAY_DNS_NAME}" "${GATEWAY_PUBLIC_IP}"
    printf 'Tunnel-Unit  %s\n' "$(systemctl --user is-active llm-reverse-tunnel.service 2>&1)"
    printf 'Schluessel   %s\n' "$([[ -f ${key_path} ]] && echo vorhanden || echo fehlt)"
    vm "ss -tln 2>/dev/null | grep -E '127.0.0.1:(${GATEWAY_LITELLM_PORT}|${GATEWAY_GRAFANA_PORT}|${GATEWAY_HOMEPAGE_PORT}) ' || echo '  (keine Tunnel-Listener)'"
    printf 'Letzte Tunnelmeldungen:\n'
    journalctl --user --no-pager -u llm-reverse-tunnel.service -n 6 2>/dev/null | cut -c1-200 || echo '  (kein Log)'
    ;;

  --apply)
    require_target
    need_cmd autossh 'Jetzt ausführen: sudo dnf install -y autossh (oder make install)'
    ensure_key
    resolve_key || die "SSH zum Gateway fehlt: ${remote} - weder ${key_path} noch ${bootstrap_path} wird akzeptiert"
    adopt_team_users
    [[ -s "${users_path}" ]] || die "Keine Basic-Auth-Personen in ${users_path} - mit $0 --hash BENUTZER anlegen, sonst sind Grafana und Homepage fuer niemanden erreichbar"
    install_authorized_key
    tmp="$(mktemp)"
    render_caddyfile > "${tmp}"
    vm "cat > /tmp/llm-gateway-Caddyfile.new" < "${tmp}"
    vm "sudo caddy validate --adapter caddyfile --config /tmp/llm-gateway-Caddyfile.new" \
      || { vm 'rm -f /tmp/llm-gateway-Caddyfile.new'; die "Caddyfile ist ungueltig - nichts installiert"; }
    vm "sudo cp -a ${GATEWAY_CADDY_FILE} ${GATEWAY_CADDY_FILE}.bak.\$(date -u +%Y%m%dT%H%M%SZ) 2>/dev/null || true
        sudo caddy fmt --overwrite /tmp/llm-gateway-Caddyfile.new 2>/dev/null || true
        sudo install -m 0644 -o root -g root /tmp/llm-gateway-Caddyfile.new ${GATEWAY_CADDY_FILE}
        sudo rm -f /tmp/llm-gateway-Caddyfile.new
        sudo systemctl reload caddy || sudo systemctl restart caddy"
    log "Caddy auf dem Gateway erneuert und neu geladen"
    install_unit
    systemctl --user enable --now llm-reverse-tunnel.service >/dev/null 2>&1 || true
    systemctl --user restart llm-reverse-tunnel.service
    rm -f "${tmp}"
    cat <<NEXT
Oeffentlicher Zugang
  LiteLLM   https://${GATEWAY_DNS_NAME}/v1   (persoenlicher Virtual-Key noetig)
  Grafana   https://${GATEWAY_DNS_NAME}/grafana/   (Basic-Auth)
  Homepage  https://${GATEWAY_DNS_NAME}/   (Basic-Auth)
  Ohne DNS-Namen geht dieselbe Adresse auch als https://${GATEWAY_PUBLIC_IP}/
Schluesselvergabe: ./scripts/71-gateway-keys.sh
Pruefen:           ./scripts/70-setup-gateway-proxy.sh --check
NEXT
    ;;

  *) die "Unbekannter Modus: $1 (erlaubt: --check, --status, --hash, kein Argument)" ;;
esac
