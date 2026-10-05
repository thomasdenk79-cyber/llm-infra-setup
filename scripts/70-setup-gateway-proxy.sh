#!/usr/bin/env bash
# Oeffentlicher HTTPS-Zugang (nur Port 443) auf der Azure-Gateway-VM.
#
# Richtet dort Caddy als Reverse-Proxy ein: ausschliesslich die LiteLLM-API
# unter /v1 (Zugriffsschutz = persoenlicher Virtual Key). Grafana, Homepage
# und alle anderen Pfade bleiben nur per SSH-Tunnel (ssh -L) erreichbar.
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

echo "=== 4. Konfiguration erzeugen und anwenden ==="
# Oeffentlich erreichbar (NSG 443 offen)? Nur dann kann Let's Encrypt via
# TLS-ALPN ein vertrauenswuerdiges Zertifikat ausstellen. Solange die
# Netzwerkregel fehlt, bleibt tls internal (Nutzer dann mit -k bzw.
# installiertem Caddy-Stammzertifikat).
nsg_offen=nein
if timeout 6 bash -c "cat < /dev/null > /dev/tcp/${GATEWAY_HOST}/443" 2>/dev/null; then
  nsg_offen=ja
fi
site="${GATEWAY_DNS_NAME:-${GATEWAY_HOST}}"
[[ "${site}" == *"://"* ]] || site="https://${site}"
tls_directive="tls internal"; global_tail=""
if [[ -n "${GATEWAY_DNS_NAME}" && "${nsg_offen}" == ja ]]; then
  tls_directive=""; [[ -n "${GATEWAY_ACME_EMAIL}" ]] && global_tail="email ${GATEWAY_ACME_EMAIL}"
  log "Port 443 ist oeffentlich erreichbar: automatisches Let's-Encrypt-Zertifikat fuer ${GATEWAY_DNS_NAME}"
elif [[ -n "${GATEWAY_DNS_NAME}" ]]; then
  log "WARNUNG: DNS-Name gesetzt, aber Port 443 ist von aussen nicht erreichbar (Azure-NSG)."
  log "Es wird einstweilen 'tls internal' verwendet. NSG oeffnen und erneut ausfuehren fuer Let's Encrypt."
fi
render_dir="${root}/state/gateway"; install -d -m 0700 "${render_dir}"
rendered="${render_dir}/Caddyfile"
sed -e "s|__SITE__|${site}|g" -e "s|__TLS__|${tls_directive}|g" \
    -e "s|__GLOBAL_TAIL__|${global_tail}|g" -e "s|__LITELLM_PORT__|${GATEWAY_LITELLM_PORT}|g" \
    "${root}/gateway/Caddyfile.template" > "${rendered}"
echo "Gerendert: ${rendered} (Site: ${site}, TLS: ${tls_directive:-automatisch})"
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

echo "=== 5. Tests auf dem Gateway (Loopback ueber 443) ==="
test_host="${GATEWAY_DNS_NAME:-${GATEWAY_HOST}}"; test_host="${test_host#*://}"
if [[ "${mode}" == "--dry-run" ]]; then
  echo "Uebersprungen (--dry-run)."
else
  # --resolve erzwingt 127.0.0.1 und damit dasselbe Zertifikat wie extern.
  c1="$(gw "curl -sk -o /dev/null -w '%{http_code}' --resolve '${test_host}:443:127.0.0.1' 'https://${test_host}/health/liveliness'" || true)"
  c2="$(gw "curl -sk -o /dev/null -w '%{http_code}' --resolve '${test_host}:443:127.0.0.1' 'https://${test_host}/v1/models'" || true)"
  c3="$(gw "curl -sk -o /dev/null -w '%{http_code}' --resolve '${test_host}:443:127.0.0.1' 'https://${test_host}/'" || true)"
  echo "liveliness: ${c1} (erwartet 200) | /v1/models ohne Token: ${c2} (erwartet 401) | /: ${c3} (erwartet 404)"
  gw "ss -tlnp | grep -E ':(80|443|3000|3002|4000) ' || echo 'Achtung: kein 443-Listener'"
fi

echo "=== 6. Externer Test von CachyOS ==="
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

echo
echo "Fertig. Naechste Schritte:"
if [[ -z "${tls_directive}" ]]; then
  echo "  * Client (Team, nur Token): curl https://${test_host}/v1/models -H 'Authorization: Bearer <persoenlicher-key>'  (vertrauenswuerdiges TLS)"
else
  echo "  * Client (Team, nur Token): curl -k https://${test_host}/v1/models -H 'Authorization: Bearer <persoenlicher-key>'  (selbst signiert: -k oder Caddy-Stammzertifikat installieren)"
fi
echo "  * Grafana/Homepage pro Person per Tunnel: ssh -i <eigener-key> -N -L 3000:127.0.0.1:3000 -L 3002:127.0.0.1:3002 ${GATEWAY_SSH_USER}@${GATEWAY_HOST}"
echo "  * Verwaltung der VM: ssh -i ${admin_key} ${GATEWAY_SSH_USER}@${GATEWAY_HOST}"
echo "  * Statuspruefung jederzeit: ./scripts/70-setup-gateway-proxy.sh --check"
