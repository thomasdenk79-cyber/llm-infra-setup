#!/usr/bin/env bash
# Oeffentlicher HTTPS-Zugang (nur Port 443) auf der Azure-Gateway-VM.
#
# Richtet dort Caddy als Reverse-Proxy ein (alles nur ueber Port 443):
#   /v1, /health/...  -> LiteLLM      (Schutz = persoenlicher Virtual Key)
#   /grafana/         -> Grafana      (Schutz = Basic-Auth pro Person;
#                                       optional Entra-ID-Login in Grafana)
#   /                 -> Homepage     (Schutz = Basic-Auth pro Person)
# Basic-Auth-Passwoerter liegen lokal unter
# ~/.config/llm-infra/gateway-web-auth/<benutzer>.txt (0600), nie in Git.
# Zusaetzlich bekommt die lokale CachyOS-Maschine einen eigenen
# Verwaltungs-Schluessel fuer die Gateway-VM.
#
# VORBEREITUNG durch den Betreiber:
#   1. cp config/gateway.env.example config/gateway.env   # ausfuellen
#   2. Azure-NSG der VM: TCP/443 auf 20.73.54.102 oeffnen (PORTAL oder az)
#   3. optional fuer vertrauenswuerdige Zertifikate: Azure-DNS-Label auf der
#      Public IP setzen und GATEWAY_DNS_NAME in config/gateway.env eintragen
#
# Verwendung:
#   ./scripts/70-setup-gateway-proxy.sh --check      Read-only-Status (nichts aendern)
#   ./scripts/70-setup-gateway-proxy.sh --dry-run    zeigen, was angewendet wuerde
#   ./scripts/70-setup-gateway-proxy.sh              installieren, konfigurieren, testen
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${root}/lib/common.sh"

env_file="${root}/config/gateway.env"
if [[ ! -f "${env_file}" ]]; then
  cat >&2 <<MSG
ABBRUCH: ${env_file} fehlt.
So geht es weiter:
  cp config/gateway.env.example config/gateway.env
  \${EDITOR:-nano} config/gateway.env
  ./scripts/70-setup-gateway-proxy.sh
MSG
  exit 1
fi
# shellcheck disable=SC1090
source "${env_file}"

: "${GATEWAY_HOST:=}"
: "${GATEWAY_SSH_USER:=azureuser}"
: "${GATEWAY_SSH_PORT:=22}"
: "${GATEWAY_SSH_KEY:=%h/.ssh/llm_gateway_reverse_ed25519}"
: "${GATEWAY_ADMIN_KEY:=%h/.ssh/llm_gateway_admin_ed25519}"
: "${GATEWAY_DNS_NAME:=}"
: "${GATEWAY_ACME_EMAIL:=}"
: "${GATEWAY_LITELLM_PORT:=4000}"
: "${GATEWAY_HOST_KEY_FINGERPRINT:=}"
: "${GATEWAY_ALLOWED_SSH_CIDRS:=}"
: "${GATEWAY_ALLOWED_WEB_CIDRS:=${GATEWAY_ALLOWED_SSH_CIDRS}}"
: "${GATEWAY_TEAM_USERS:=owner}"
: "${GATEWAY_GRAFANA_PORT:=3000}"
: "${GATEWAY_HOMEPAGE_PORT:=3002}"
: "${GATEWAY_TLS:=internal}"
: "${GATEWAY_AZUREAD_TENANT_ID:=}"
: "${GATEWAY_AZUREAD_CLIENT_ID:=}"
: "${GATEWAY_AZUREAD_CLIENT_SECRET:=}"
: "${GATEWAY_AZUREAD_ALLOWED_DOMAINS:=siemens.com}"
auth_store="${HOME}/.config/llm-infra/gateway-web-auth"

[[ -n "${GATEWAY_HOST}" && "${GATEWAY_HOST}" != example.net ]] || {
  echo "ABBRUCH: GATEWAY_HOST ist nicht gesetzt. Naechster Befehl: \${EDITOR:-nano} config/gateway.env" >&2; exit 1; }

expand_key() { printf '%s' "${1/\%h/${HOME}}"; }
tunnel_key="$(expand_key "${GATEWAY_SSH_KEY}")"
admin_key="$(expand_key "${GATEWAY_ADMIN_KEY}")"
state_dir="${HOME}/.local/share/llm-infra/ssh"
install -d -m 0700 "${state_dir}"
touch "${state_dir}/known_hosts"; chmod 0600 "${state_dir}/known_hosts"

need_cmd ssh 'SSH fehlt. Jetzt ausfuehren: make tools'
need_cmd scp 'SCP fehlt. Jetzt ausfuehren: make tools'

mode="${1:-}"
[[ "${mode}" =~ ^(--check|--dry-run|)$ ]] || {
  echo "ABBRUCH: unbekannter Modus '${mode}'. Naechster Befehl: ./scripts/70-setup-gateway-proxy.sh --help" >&2
  sed -n '2,20p' "${BASH_SOURCE[0]}" >&2; exit 1; }

ssh_base=(-o BatchMode=yes -o ConnectTimeout=10 -o IdentitiesOnly=yes
          -o StrictHostKeyChecking=accept-new
          -o UserKnownHostsFile="${state_dir}/known_hosts"
          -p "${GATEWAY_SSH_PORT}")
gw_with() { local key="$1"; shift
  ssh "${ssh_base[@]}" -i "${key}" "${GATEWAY_SSH_USER}@${GATEWAY_HOST}" "$@"; }
USE_KEY=""
gw() {
  if [[ -z "${USE_KEY}" ]]; then
    for k in "${admin_key}" "${tunnel_key}"; do
      [[ -f "${k}" ]] || continue
      if ssh "${ssh_base[@]}" -o BatchMode=yes -i "${k}" \
           "${GATEWAY_SSH_USER}@${GATEWAY_HOST}" true 2>/dev/null; then USE_KEY="${k}"; break; fi
    done
    [[ -n "${USE_KEY}" ]] || {
      echo "ABBRUCH: keine Schluessel-Authentifizierung moeglich (${admin_key}, ${tunnel_key})." >&2
      echo "Naechster Befehl: ./scripts/61-install-autossh.sh --check" >&2; exit 1; }
  fi
  gw_with "${USE_KEY}" "$@"
}

echo "=== 1. Verbindung und Host-Key ==="
gw 'echo "Verbunden: $(hostname) ($(lsb_release -ds))"'
if [[ -n "${GATEWAY_HOST_KEY_FINGERPRINT}" ]]; then
  shown="$(ssh-keygen -F "${GATEWAY_HOST}" -f "${state_dir}/known_hosts" -l 2>/dev/null | grep -oE 'SHA256:[A-Za-z0-9+/=]+' | head -1)"
  if [[ -z "${shown}" || "${shown}" != "${GATEWAY_HOST_KEY_FINGERPRINT}" ]]; then
    echo "ABBRUCH: Gateway-Host-KeyWeicht ab. erwartet=${GATEWAY_HOST_KEY_FINGERPRINT} gefunden=${shown:-keiner}" >&2
    echo "Erst live verifizieren, dann config/gateway.env anpassen - nichts sonst ausfuehren." >&2
    exit 1
  fi
  echo "Host-Key passt: ${shown}"
fi
USE_KEY="${admin_key}"; gw true >/dev/null 2>&1 || USE_KEY="${tunnel_key}"
echo "Genutzter Schluessel: ${USE_KEY}"

echo "=== 2. Verwaltungs-Schluessel der CachyOS-Maschine ==="
if [[ ! -f "${admin_key}" ]]; then
  if [[ "${mode}" == "--check" ]]; then
    echo "NICHT VORHANDEN: ${admin_key} (wird beim normalen Lauf erzeugt)"
  else
    run ssh-keygen -t ed25519 -f "${admin_key}" -N '' -C "cachyos2-admin@$(hostname)"
    chmod 0600 "${admin_key}"
  fi
fi
if [[ -f "${admin_key}.pub" ]]; then
  pub="$(cat "${admin_key}.pub")"
  if [[ "${mode}" == "--check" ]]; then
    if gw "grep -qF '${pub}' ~/.ssh/authorized_keys"; then echo "Admin-Key am Gateway hinterlegt: ja"
    else echo "Admin-Key am Gateway hinterlegt: NEIN (wird beim normalen Lauf ergaenzt)"; fi
  elif [[ "${mode}" != "--dry-run" ]]; then
    # nur anhaengen, nie ersetzen
    gw "install -d -m 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && grep -qF '${pub}' ~/.ssh/authorized_keys || echo '${pub}' >> ~/.ssh/authorized_keys"
    echo "Admin-Key hinterlegt (Vorhandenes unveraendert)."
  fi
fi

echo "=== 3. Caddy auf dem Gateway ==="
if gw 'command -v caddy' >/dev/null 2>&1; then
  echo "Caddy vorhanden: $(gw 'caddy version')"
elif [[ "${mode}" != "--check" && "${mode}" != "--dry-run" ]]; then
  log "Installiere Caddy aus dem offiziellen Paketlager (cloudsmith, nur wenn fehlend)."
  gw 'sudo bash -s' <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl gnupg ca-certificates >/dev/null
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
  | gpg --yes --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
  > /etc/apt/sources.list.d/caddy-stable.list
apt-get update -qq
apt-get install -y -qq caddy >/dev/null
caddy version
REMOTE
else
  echo "Caddy ist NICHT installiert (wird beim normalen Lauf installiert)."
fi

echo "=== 4. Team-Zugangsdaten (Basic-Auth fuer Grafana und Homepage) ==="
install -d -m 0700 "${auth_store}"
read -r u0 _ <<<"${GATEWAY_TEAM_USERS}"
for u in ${GATEWAY_TEAM_USERS}; do
  f="${auth_store}/${u}.txt"
  if [[ ! -f "${f}" ]]; then
    if [[ "${mode}" == "--check" || "${mode}" == "--dry-run" ]]; then
      echo "Passwort-Datei fehlt (wird im echten Lauf angelegt): ${f}"
      continue
    fi
    pw="$(openssl rand -hex 12)"
    printf '%s\n' "${pw}" > "${f}"; chmod 0600 "${f}"
    log "Neues Basic-Auth-Passwort fuer '${u}' angelegt: ${f} (einmalig anzeigen: cat ${f})"
  fi
done

echo "=== 5. Konfiguration erzeugen und anwenden ==="
# TLS-Modus: internal = Caddy-eigene CA (Team installiert das Stammzertifikat,
# noetig sobald die NSG 443 auf eigene Kreise beschraenkt ist und Let's
# Encrypt nicht mehr erreichbar ist). letsencrypt = vertrauenswuerdig,
# erfordert oeffentlich erreichbaren Port 443 (auch fuer die Erneuerung).
site="${GATEWAY_DNS_NAME:-${GATEWAY_HOST}}"
[[ "${site}" == *"://"* ]] || site="https://${site}"
tls_directive="tls internal"; global_tail=""
nsg_offen=nein
if timeout 6 bash -c "cat < /dev/null > /dev/tcp/${GATEWAY_HOST}/443" 2>/dev/null; then nsg_offen=ja; fi
case "${GATEWAY_TLS}" in
  internal)
    [[ -n "${GATEWAY_DNS_NAME}" ]] || {
      echo "ABBRUCH: GATEWAY_TLS=internal braucht GATEWAY_DNS_NAME (Curl sendet kein SNI fuer blosse IP-Adressen)." >&2
      echo "Naechster Befehl: Azure-DNS-Label setzen und GATEWAY_DNS_NAME in config/gateway.env eintragen." >&2; exit 1; } ;;
  letsencrypt)
    [[ -n "${GATEWAY_DNS_NAME}" ]] || { echo "ABBRUCH: GATEWAY_TLS=letsencrypt braucht GATEWAY_DNS_NAME." >&2; exit 1; }
    tls_directive=""; [[ -n "${GATEWAY_ACME_EMAIL}" ]] && global_tail="email ${GATEWAY_ACME_EMAIL}"
    if [[ "${nsg_offen}" != ja ]]; then
      echo "WARNUNG: Port 443 ist von hier nicht erreichbar - Let's Encrypt braucht oeffentlich erreichbares 443." >&2
    fi ;;
  auto)
    if [[ -n "${GATEWAY_DNS_NAME}" && "${nsg_offen}" == ja ]]; then
      tls_directive=""; [[ -n "${GATEWAY_ACME_EMAIL}" ]] && global_tail="email ${GATEWAY_ACME_EMAIL}"
    fi ;;
  *) echo "ABBRUCH: GATEWAY_TLS='${GATEWAY_TLS}' unbekannt (internal|letsencrypt|auto)." >&2; exit 1 ;;
esac
render_dir="${root}/state/gateway"; install -d -m 0700 "${render_dir}"
users_block="${render_dir}/team-users.block"
: > "${users_block}"
for u in ${GATEWAY_TEAM_USERS}; do
  f="${auth_store}/${u}.txt"
  if [[ -f "${f}" ]]; then
    pw="$(head -n1 "${f}")"
    hash="$(printf '%s\n' "${pw}" | gw 'IFS= read -r p && caddy hash-password --plaintext "$p"' | tail -n1)"
    [[ -n "${hash}" ]] || { echo "ABBRUCH: caddy hash-password fehlgeschlagen fuer ${u}." >&2; exit 1; }
    printf '\t\t\t%s %s\n' "${u}" "${hash}" >> "${users_block}"
  else
    printf '\t\t\t# %s: Passwortdatei fehlt\n' "${u}" >> "${users_block}"
  fi
done
rendered="${render_dir}/Caddyfile"
sed -e "s|__SITE__|${site}|g" -e "s|__TLS__|${tls_directive}|g" \
    -e "s|__GLOBAL_TAIL__|${global_tail}|g" -e "s|__LITELLM_PORT__|${GATEWAY_LITELLM_PORT}|g" \
    -e "s|__GRAFANA_PORT__|${GATEWAY_GRAFANA_PORT}|g" -e "s|__HOMEPAGE_PORT__|${GATEWAY_HOMEPAGE_PORT}|g" \
    "${root}/gateway/Caddyfile.template" > "${render_dir}/.Caddyfile.step1"
awk -v ub="${users_block}" '{ if ($0 ~ /^[[:space:]]*__TEAM_USERS__[[:space:]]*$/) { while ((getline l<ub)>0) print l; close(ub) } else print }' \
    "${render_dir}/.Caddyfile.step1" > "${rendered}"
rm -f "${render_dir}/.Caddyfile.step1"
echo "Gerendert: ${rendered} (Site: ${site}, TLS: ${tls_directive:-automatisch}, Team: ${GATEWAY_TEAM_USERS})"
if [[ "${mode}" == "--check" ]]; then
  echo "--- aktuelles /etc/caddy/Caddyfile (Read-only) ---"
  gw 'sudo test -r /etc/caddy/Caddyfile && sudo cat /etc/caddy/Caddyfile || echo "kein /etc/caddy/Caddyfile"'
elif [[ "${mode}" == "--dry-run" ]]; then
  echo "--- wuerde folgendes anwenden ---"; cat "${rendered}"
else
  scp "${ssh_base[@]/%-p/-P}" -q -i "${USE_KEY}" "${rendered}" \
      "${GATEWAY_SSH_USER}@${GATEWAY_HOST}:/tmp/llm-gateway-Caddyfile" >/dev/null
  gw 'sudo bash -s' <<'REMOTE'
set -euo pipefail
new=/tmp/llm-gateway-Caddyfile
caddy validate --config "${new}" --adapter caddyfile
target=/etc/caddy/Caddyfile
if [[ -f "${target}" ]] && ! cmp -s "${new}" "${target}"; then
  install -d -m 0755 /etc/caddy/backup
  install -m 0600 "${target}" "/etc/caddy/backup/Caddyfile.$(date -u +%Y%m%dT%H%M%SZ)"
  echo "Vorherige Konfiguration gesichert nach /etc/caddy/backup/"
fi
if ! cmp -s "${new}" "${target}" 2>/dev/null; then
  install -m 0644 -o root -g root "${new}" "${target}"
  systemctl enable --now caddy
  # reload braucht das Admin-API; die Konfiguration setzt "admin off",
  # deshalb kontrollierter Neustart (kurz, zustandsloser Proxy).
  systemctl restart caddy
  echo "Caddy-Konfiguration angewendet."
else
  systemctl enable --now caddy
  echo "Konfiguration unveraendert; Dienst laeuft."
fi
rm -f "${new}"
systemctl is-active caddy
REMOTE
fi

echo "=== 6. Tests auf dem Gateway (Loopback ueber 443) ==="
test_host="${GATEWAY_DNS_NAME:-${GATEWAY_HOST}}"; test_host="${test_host#*://}"
if [[ "${mode}" == "--dry-run" ]]; then
  echo "Uebersprungen (--dry-run)."
else
  # --resolve erzwingt 127.0.0.1 und damit dasselbe Zertifikat wie extern.
  c1="$(gw "curl -sk -o /dev/null -w '%{http_code}' --resolve '${test_host}:443:127.0.0.1' 'https://${test_host}/health/liveliness'" || true)"
  c2="$(gw "curl -sk -o /dev/null -w '%{http_code}' --resolve '${test_host}:443:127.0.0.1' 'https://${test_host}/v1/models'" || true)"
  c3="$(gw "curl -sk -o /dev/null -w '%{http_code}' --resolve '${test_host}:443:127.0.0.1' 'https://${test_host}/'" || true)"
  c4="$(gw "curl -sk -o /dev/null -w '%{http_code}' --resolve '${test_host}:443:127.0.0.1' 'https://${test_host}/grafana/'" || true)"
  echo "liveliness: ${c1} (200) | /v1 ohne Token: ${c2} (401) | / ohne Basic: ${c3} (401) | /grafana/ ohne Basic: ${c4} (401)"
  if [[ -n "${u0:-}" && -f "${auth_store}/${u0}.txt" ]]; then
    pw0="$(head -n1 "${auth_store}/${u0}.txt")"
    ch="$(printf 'user = "%s:%s"\n' "${u0}" "${pw0}" | gw "curl -sk -o /dev/null -w '%{http_code}' --config - --resolve '${test_host}:443:127.0.0.1' 'https://${test_host}/'" || true)"
    cg="$(printf 'user = "%s:%s"\n' "${u0}" "${pw0}" | gw "curl -sk -o /dev/null -w '%{http_code}' --config - --resolve '${test_host}:443:127.0.0.1' 'https://${test_host}/grafana/'" || true)"
    echo "mit Team-Login (${u0}): Homepage ${ch} (200) | Grafana ${cg} (302 auf Login)"
  fi
  gw "ss -tlnp | grep -E ':(80|443|3000|3002|4000) ' || echo 'Achtung: kein 443-Listener'"
  if [[ "${tls_directive}" == "tls internal" ]]; then
    rootcrt="${render_dir}/caddy-root.crt"
    if gw 'sudo cat /var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt >/dev/null 2>&1'; then
      gw 'sudo cat /var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt' > "${rootcrt}" && chmod 0600 "${rootcrt}"
      echo "Caddy-Stammzertifikat: ${rootcrt} (Team einmalig als vertrauenswuerdig installieren, sonst -k)"
    fi
  fi
fi

echo "=== 7. Externer Test von CachyOS ==="
if [[ "${mode}" == "--dry-run" ]]; then
  echo "Uebersprungen (--dry-run)."
elif curl -k -m 8 -o /dev/null -sL "https://${test_host}/health/liveliness" 2>/dev/null; then
  echo "Externer Zugriff auf Port 443 funktioniert."
else
  cat >&2 <<MSG
Noch kein externer Zugriff auf Port 443 (Timeout oder TLS-Vertrauen).
Haeufigste Ursache: die Azure-Netzwerkregel (NSG) laesst TCP/443 nicht durch.
Betreiber-Auftrag im Azure-PORTAL:
  VM edipoc-gateway -> Netzwerksecuritygruppe -> Eingehende Sicherheitsregeln ->
  Neu: Dienst "HTTPS", Port 443, Quelle Internet, Zulassen.
Danach erneut: ./scripts/70-setup-gateway-proxy.sh --check
MSG
fi

echo "=== 8. Zugangsschutz Port 22 und 443 (Azure-NSG) ==="
own_ip="$(curl -s -m 8 https://api.ipify.org 2>/dev/null || true)"
[[ -n "${own_ip}" ]] || own_ip="$(curl -s -m 8 https://ifconfig.me/ip 2>/dev/null || true)"
echo "Aktuelle oeffentliche IP dieser CachyOS-Maschine: ${own_ip:-unbekannt}"
if [[ -n "${GATEWAY_ALLOWED_SSH_CIDRS}" ]]; then
  echo "Erlaubte SSH-Kreise laut config/gateway.env: ${GATEWAY_ALLOWED_SSH_CIDRS}"
  if [[ -n "${own_ip}" ]]; then
    need_cmd python3 'Python fehlt. Jetzt ausfuehren: make tools'
    if GATEWAY_ALLOWED_SSH_CIDRS="${GATEWAY_ALLOWED_SSH_CIDRS}" own_ip="${own_ip}" python3 - <<'PY'
import ipaddress, os, sys
ip = ipaddress.ip_address(os.environ["own_ip"])
nets = [c.strip() for c in os.environ["GATEWAY_ALLOWED_SSH_CIDRS"].replace(",", " ").split() if c.strip()]
try:
    sys.exit(0 if any(ip in ipaddress.ip_network(n) for n in nets) else 1)
except ValueError as exc:
    print(f"Ungueltiger CIDR-Eintrag: {exc}", file=sys.stderr); sys.exit(2)
PY
    then echo "Der eigene Zugriff (diese Maschine) ist abgedeckt."
    else echo "ACHTUNG: Die eigene IP ${own_ip} fehlt in GATEWAY_ALLOWED_SSH_CIDRS." >&2
         echo "Nach dem NSG-Lockdown ist diese Maschine ausgesperrt (auch der Autossh-Tunnel!)." >&2
         echo "Naechster Befehl: \${EDITOR:-nano} config/gateway.env  # IP ergaenzen, dann erneut laufen lassen" >&2
         if [[ "${mode}" != "--check" && "${mode}" != "--dry-run" ]]; then exit 1; fi
    fi
  fi
  echo "Port 22 braucht nur noch CachyOS (Tunnel+Verwaltung) und der Betreiber."
  echo "Das Team erreicht Grafana/Homepage/LiteLLM ueber Port 443 (Quelle: WEB-Kreise)."
  # Prueft nach einem NSG-Lockdown, ob Port 22 von hier ueberhaupt durchkommt.
  if timeout 6 bash -c "cat < /dev/null > /dev/tcp/${GATEWAY_HOST}/22" 2>/dev/null; then
    echo "Port-22-Test von dieser Maschine: erreichbar."
  else
    echo "ACHTUNG: Port 22 ist von dieser Maschine nicht erreichbar - die NSG-Regel" >&2
    echo "passt nicht zur aktuellen IP ${own_ip:-?} (Neueinwahl?). Autossh-Tunnel steht still." >&2
    echo "Heilung im Azure-PORTAL: Quelle der SSH-Regel auf ${own_ip:-<aktuelle IP>}/32 setzen." >&2
  fi
  echo
  echo "Umsetzung im Azure-PORTAL (NSG der VM edipoc-gateway, RG-EDIPOC-WEU):"
  echo "  Regel 'allow-ssh-cachyos' TCP 22, Quelle:"
  tr ',;' '  ' <<<"${GATEWAY_ALLOWED_SSH_CIDRS}" | tr ' ' '\n' | grep -E '^[0-9][0-9.]+/[0-9]+$' | sed 's/^/    - /'
  echo "  Regel 'allow-web-team' TCP 443 (plus 80 fuer HTTP->HTTPS), Quelle:"
  tr ',;' '  ' <<<"${GATEWAY_ALLOWED_WEB_CIDRS}" | tr ' ' '\n' | grep -E '^[0-9][0-9.]+/[0-9]+$' | sed 's/^/    - /'
  echo "  Beide Regeln ausserdem um weitere Betreiber-IPs erweitern, falls von anderen Netzen verwaltet wird."
  echo "  Loeschen: jede Regel mit Quelle 'Any' auf 22/3000/8080; 443 nur 'Any' wenn GATEWAY_TLS=letsencrypt."
  echo "Mit Azure-CLI (auf einem Rechner mit 'az login'), NSG-Namen vorher pruefen:"
  echo "  az network nsg rule update -g RG-EDIPOC-WEU --nsg-name <NSG-NAME> \\"
  echo "    --name allow-ssh-cachyos --source-address-prefixes $(tr ',;' '  ' <<<"${GATEWAY_ALLOWED_SSH_CIDRS}" | tr -s ' ' '\n' | grep -E '^[0-9][0-9.]+/[0-9]+$' | paste -sd, -)"
  echo "  az network nsg rule update -g RG-EDIPOC-WEU --nsg-name <NSG-NAME> \\"
  echo "    --name allow-web-team --destination-port-ranges 80-443 --source-address-prefixes $(tr ',;' '  ' <<<"${GATEWAY_ALLOWED_WEB_CIDRS}" | tr -s ' ' '\n' | grep -E '^[0-9][0-9.]+/[0-9]+$' | paste -sd, -)"
else
  echo "Keine GATEWAY_ALLOWED_SSH_CIDRS gesetzt - Port 22 ist weiterhin 'Any'. Empfehlung:"
  echo "  In config/gateway.env eigene IP ${own_ip:-<aktuell>}/33 eintragen,"
  echo "  dazu die Netz-Kreise von martin, johannes, holger, dann erneut ausfuehren."
fi
echo "=== 9. Entra-ID-Login fuer Grafana (optional) ==="
grafana_env="${HOME}/.config/llm-infra/grafana.env"
if [[ -n "${GATEWAY_AZUREAD_TENANT_ID}" && -n "${GATEWAY_AZUREAD_CLIENT_ID}" && -n "${GATEWAY_AZUREAD_CLIENT_SECRET}" ]]; then
  desired="$(printf '%s\n' \
    "GF_AUTH_AZUREAD_ENABLED=true" \
    "GF_AUTH_AZUREAD_NAME=Entra-ID" \
    "GF_AUTH_AZUREAD_TENANT_ID=${GATEWAY_AZUREAD_TENANT_ID}" \
    "GF_AUTH_AZUREAD_CLIENT_ID=${GATEWAY_AZUREAD_CLIENT_ID}" \
    "GF_AUTH_AZUREAD_CLIENT_SECRET=${GATEWAY_AZUREAD_CLIENT_SECRET}" \
    "GF_AUTH_AZUREAD_ALLOW_SIGN_UP=true" \
    "GF_AUTH_AZUREAD_ALLOWED_DOMAINS=${GATEWAY_AZUREAD_ALLOWED_DOMAINS}" \
    "GF_AUTH_OAUTH_AUTO_ASSIGN_ROLE=true" \
    "GF_USERS_DEFAULT_ORG_ROLE=Viewer")"
  if [[ -f "${grafana_env}" && "$(cat "${grafana_env}")" == "${desired}" ]]; then
    echo "Grafana-Entra-Konfiguration unveraendert: ${grafana_env}"
  elif [[ "${mode}" == "--check" || "${mode}" == "--dry-run" ]]; then
    echo "Entra-Werte gesetzt, aber noch nicht angewendet (Modus ${mode:-apply} aendert sie)."
  else
    install -d -m 0700 "${HOME}/.config/llm-infra"
    printf '%s\n' "${desired}" > "${grafana_env}.new"
    chmod 0600 "${grafana_env}.new"
    mv "${grafana_env}.new" "${grafana_env}"
    log "Grafana neu gestartet (nur Grafana, keine Runtime): Entra-Login aktiv"
    systemctl --user restart grafana.service
  fi
else
  echo "Entra-ID noch nicht konfiguriert (Grund: Basic-Auth genuegt vorerst)."
  echo "Fuer den Siemens-Login braucht es eine Azure-App-Registrierung (Entra ID) mit"
  echo "Umleitungs-URI https://${test_host:-<fqdn>}/login/azuread - dann in"
  echo "config/gateway.env ausfuellen: GATEWAY_AZUREAD_TENANT_ID, _CLIENT_ID, _CLIENT_SECRET."
fi
echo
echo "Fertig. Naechste Schritte:"
if [[ -z "${tls_directive}" ]]; then
  echo "  * Client (Team, nur Token): curl https://${test_host}/v1/models -H 'Authorization: Bearer <persoenlicher-key>'  (vertrauenswuerdiges TLS)"
else
  echo "  * Client (Team, nur Token): curl -k https://${test_host}/v1/models -H 'Authorization: Bearer <persoenlicher-key>'  (selbst signiert: -k oder Caddy-Stammzertifikat installieren)"
fi
echo "  * Team im Browser: https://${test_host}/ (Homepage) und https://${test_host}/grafana/  (Login: ${GATEWAY_TEAM_USERS} - Passwoerter: cat ${auth_store}/<name>.txt)"
echo "  * Admin-Browserlogin fuer den Betreiber: wie Team plus Grafana-Login 'admin' (./scripts/show-credentials.sh)"
echo "  * Verwaltung der VM: ssh -i ${admin_key} ${GATEWAY_SSH_USER}@${GATEWAY_HOST}"
echo "  * Statuspruefung jederzeit: ./scripts/70-setup-gateway-proxy.sh --check"
