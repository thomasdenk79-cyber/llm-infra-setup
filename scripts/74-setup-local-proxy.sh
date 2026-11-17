#!/usr/bin/env bash
# HTTPS-Zugang ueber Namen: ein verwalteter Caddy, der im Repo liegt und im Netz
# llm-observability wohnt (bei aktivem LAN zusaetzlich in llm-inference).
#
#   ./scripts/74-setup-local-proxy.sh                alles einrichten (Standard)
#   ./scripts/74-setup-local-proxy.sh --plan         zeigen, was sich aendert (aendert nichts)
#   ./scripts/74-setup-local-proxy.sh --check        pruefen, nichts aendern
#   ./scripts/74-setup-local-proxy.sh --render       nur Dateien schreiben (make drift)
#   ./scripts/74-setup-local-proxy.sh --ca-import    Caddy-CA in den Systemtrust (dieser Rechner)
#   ./scripts/74-setup-local-proxy.sh --ca-export    CA-Datei fuer Windows ausgeben
#   ./scripts/74-setup-local-proxy.sh --print-hosts  Eintrag fuer die Windows-hosts-Datei
#   ./scripts/74-setup-local-proxy.sh --lan-credentials  Pfad der Zugangsdaten (ohne Werte)
#   ./scripts/74-setup-local-proxy.sh --status       Kurzbild des Ist-Zustands
#
# Was dabei entsteht:
#   1. config/proxy/Caddyfile       - gerendert aus config/proxy/Caddyfile.template
#   2. quadlet/llm-proxy.container  - Unit-Datei mit Header "GENERIERT von"
#   3. die Benutzer-Unit llm-proxy.service (Netze, 127.0.0.1:443, ggf. LAN-Adressen)
#   4. ~/.config/llm-infra/proxy/lan-auth.env         (0600) bcrypt-Hashes fuer Caddy
#      ~/.config/llm-infra/proxy/lan-credentials.txt (0600) dieselben Zugangsdaten lesbar
#
# Sites: Loopback immer, LAN nur mit LAN_BIND_IPS in config/host.env.
#   Loopback  homepage.localhost, grafana.localhost                     (Bestand)
#   LAN       homepage|grafana|littlem|llm-direct|dozzle|direct-llm.<LAN_DOMAIN>
#
# Wer was schuetzt:
#   - LiteLLM ("littlem", Alias "llm-direct") verlangt den Gateway-Schluessel selbst,
#     ohne Schluessel 401. Ein eigenes Passwort waere Doppelarbeit.
#   - Dozzle und die direkte vLLM-Route haben stromaufwaerts keine Anmeldung, deshalb
#     Basic-Auth im Proxy. Die Zugangsdaten liegen ausserhalb von Git (0600); das
#     Caddyfile enthaelt nur {env.*}-Platzhalter.
#   - Prometheus, Alertmanager, Loki, Grafana-, Dozzle-, Gateway- und Runtime-Port
#     bleiben auf dem Loopback; nur 443 geht aufs LAN (--check prueft das nach).
#
# rootless podman: Der Container hoert im Netz auf 443, aber das Veroeffentlichen
# auf dem Host macht rootlessport als normaler Benutzer - unterhalb der
# unprivileged_port_start-Grenze (hier 1024) verweigert der Kernel das
# (gemessen: pasta "Listen failed ... Permission denied"). Der Generator senkt
# die Grenze auf 443 ueber eine eigene Datei in /etc/sysctl.d/ (sudo,
# idempotent, reversible). Bewusst 443 und nicht 80: nur der HTTPS-Port wird
# gebraucht, 80..442 bleiben privilegiert.
#
# Die bestehenden Caddy-Konfigurationen (Gateway-VM ueber 70-setup-gateway-proxy.sh,
# Wiki ueber 60-install-wiki.sh) bleiben unangetastet.
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${root}/lib/common.sh"
source "${root}/lib/units.sh"
[[ -f "${root}/config/host.env" ]] && source "${root}/config/host.env"

CADDY_IMAGE='docker.io/library/caddy:2-alpine'   # wie wiki.container, hier schon im Bestand
TEMPLATE="${root}/config/proxy/Caddyfile.template"
RENDERED="${root}/config/proxy/Caddyfile"
QUADLET="${root}/quadlet/llm-proxy.container"
SYSCTL_FILE='/etc/sysctl.d/99-llm-infra-local-proxy.conf'
SYSCTL_KEY='net.ipv4.ip_unprivileged_port_start'
SYSCTL_WANT=443
CADDY_HOME="${HOME}/.local/share/llm-infra/caddy"
CA_DIR="${CADDY_HOME}/ca"
CA_FILE="${CA_DIR}/caddy-local-authority-root.crt"
AUTH_DIR="${HOME}/.config/llm-infra/proxy"
AUTH_ENV_FILE="${AUTH_DIR}/lan-auth.env"
CRED_FILE="${AUTH_DIR}/lan-credentials.txt"
# Uebergangsform von 2026-11-17: die Bind-IP lag zuerst in einer eigenen Datei
# unter ~/.config/llm-infra. host.env hat Vorrang; die Datei wird nur gelesen,
# wenn host.env nichts sagt, damit ein bereits eingerichteter Rechner weiterlaeuft.
LEGACY_BIND_IP_FILE="${HOME}/.config/llm-infra/llm-direct-bind-ip"
UNIT='llm-proxy.container'

# Upstream-Namen: so, wie sie im jeweiligen Netz aufloesen (gemessen mit getent in
# einem Wegwerf-Container). Ports sind die internen Ports der Quadlets.
HOMEPAGE_UPSTREAM='llm-homepage:3000'
GRAFANA_UPSTREAM='grafana:3000'
DOZZLE_UPSTREAM='dozzle:8080'
LITELLM_UPSTREAM='litellm:4000'
# Die Runtime laeuft als unmanaged Container im pasta-Netz und ist von aussen nur
# ueber den Weiterleiter erreichbar (scripts/73-setup-vllm-forwarder.sh). Die
# Host-Loopback reicht rootless pasta nicht an Container durch, deshalb der
# Gateway-Name host.containers.internal statt 127.0.0.1.
: "${VLLM_FORWARD_PORT:=30001}"
DIRECT_LLM_UPSTREAM="host.containers.internal:${VLLM_FORWARD_PORT}"

ist_ipv4() {
  # ist_ipv4 <text> -> 0 bei gueltiger IPv4 in Punktnotation. Die Zahlenbereiche
  # werden mitgeprueft: "192.168.0.999" ist keine Adresse, auch wenn sie vier
  # Zifferngruppen hat, und podman wuerde die Veroeffentlichung still ignorieren.
  local ip="$1" teil
  [[ "${ip}" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r -a teile <<< "${ip}"
  for teil in "${teile[@]}"; do
    (( 10#${teil} <= 255 )) || return 1
  done
  return 0
}

# --- LAN-Konfiguration (Werte in config/host.env) -----------------------------
: "${LAN_DOMAIN:=$(hostname 2>/dev/null || echo llmhost)}"
: "${LAN_BIND_IPS:=}"
: "${LAN_DOZZLE_USER:=operator}"
: "${LAN_DIRECT_LLM_USER:=operator}"
if [[ -z "${LAN_BIND_IPS//[[:space:],]/}" && -f "${LEGACY_BIND_IP_FILE}" ]]; then
  LAN_BIND_IPS="$(tr -d ' \t\r\n' < "${LEGACY_BIND_IP_FILE}")"
fi
LAN_IPS=()
read -r -a LAN_IPS <<< "${LAN_BIND_IPS//,/ }" || true
lan_enabled=0
if (( ${#LAN_IPS[@]} > 0 )); then
  lan_enabled=1
  for lan_ip in "${LAN_IPS[@]}"; do
    ist_ipv4 "${lan_ip}" || die \
      "LAN_BIND_IPS enthaelt keine gueltige IPv4: '${lan_ip}'. Setzen in ${root}/config/host.env (zum Beispiel LAN_BIND_IPS=192.168.0.198), dann: ./scripts/74-setup-local-proxy.sh"
  done
  [[ "${LAN_DOMAIN}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,62}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,62}[A-Za-z0-9])?)*$ ]] || die \
    "LAN_DOMAIN ist kein gueltiger Rechnername: '${LAN_DOMAIN}'. Setzen in ${root}/config/host.env, dann erneut ausfuehren."
fi
# Reihenfolge ist Teil der gerenderten Dateien: gleiche Reihenfolge = gleiche
# Ausgabe, und darauf vergleicht make drift.
LAN_ROLES=(homepage grafana littlem llm-direct dozzle direct-llm)
# Ports, die ausschliesslich auf dem Loopback bleiben muessen (--check). Der
# Weiterleiter-Port 30001 fehlt bewusst: er bindet den Host, damit Container im
# Inferenz-Netz die Runtime erreichen (docs/runtime.md).
LOOPBACK_ONLY_PORTS=(3000 3001 3002 3100 4000 5432 8080 9090 9093 9835 30000)

lan_hosts() {
  # LAN-Rechnernamen in fester Reihenfolge; fuer Checks, hosts-Datei und Ausgabe.
  local rolle
  for rolle in "${LAN_ROLES[@]}"; do printf '%s.%s\n' "${rolle}" "${LAN_DOMAIN}"; done
}

render_lan_sites() {
  # Leere Ausgabe, wenn kein LAN konfiguriert ist: dann bleibt der Zugang Loopback-only.
  (( ${lan_enabled} == 1 )) || return 0
  cat <<SITE
# --- LAN-Zugang ---------------------------------------------------------------
# Gerendert aus config/proxy/Caddyfile.template durch scripts/74-setup-local-proxy.sh.
# Alle Namen enden auf den Rechnernamen (${LAN_DOMAIN}); Windows-Clients tragen sie in
# C:\Windows\System32\drivers\etc\hosts ein (docs/operations.md, Abschnitt LAN-Zugang).
# Die Zugangsdaten der Basic-Auth-Routen stehen in ${AUTH_ENV_FILE}
# (0600, ausserhalb von Git); im Caddyfile stehen nur {env.*}-Platzhalter.

homepage.${LAN_DOMAIN} {
	tls internal
	encode zstd gzip

	handle /anleitung* {
		root * /srv/llm-proxy/site
		file_server
	}

	handle {
		reverse_proxy ${HOMEPAGE_UPSTREAM}
	}
}

grafana.${LAN_DOMAIN} {
	# Bewusst ohne Anmeldung: anonyme Lese-Rolle in ~/.config/llm-infra/grafana.env.
	# Der Unterpfad /grafana/ bleibt, damit GF_SERVER_ROOT_URL weiterhin passt.
	tls internal
	encode zstd gzip
	reverse_proxy ${GRAFANA_UPSTREAM}
}

# Gateway (LiteLLM): verlangt den eigenen Virtual-Key, 401 ohne Schluessel.
littlem.${LAN_DOMAIN} {
	tls internal
	encode zstd gzip
	reverse_proxy ${LITELLM_UPSTREAM}
}

# Alias von littlem.${LAN_DOMAIN}: dieselbe Adresse unter dem Namen von 2026-11-17.
llm-direct.${LAN_DOMAIN} {
	tls internal
	encode zstd gzip
	reverse_proxy ${LITELLM_UPSTREAM}
}

# Container-Logs: Basic-Auth, weil Logs Zugangswerte enthalten koennen.
dozzle.${LAN_DOMAIN} {
	tls internal
	basic_auth {
		{env.LLM_LAN_DOZZLE_USER} {env.LLM_LAN_DOZZLE_HASH}
	}
	encode zstd gzip
	reverse_proxy ${DOZZLE_UPSTREAM}
}

# vLLM direkt (Diagnose, lokale Werkzeuge): die Runtime selbst kennt keine
# Anmeldung, deshalb Basic-Auth hier. Ziel ist der Weiterleiter auf dem Host.
direct-llm.${LAN_DOMAIN} {
	tls internal
	basic_auth {
		{env.LLM_LAN_DIRECT_LLM_USER} {env.LLM_LAN_DIRECT_LLM_HASH}
	}
	encode zstd gzip
	reverse_proxy ${DIRECT_LLM_UPSTREAM}
}

# Unbekannte Hostnamen: keine Site, keine Weiterleitung an einen Backend-Port.
:443 {
	tls internal
	respond "Unbekannter Name" 403
}
SITE
}

render_caddyfile() {
  [[ -f "${TEMPLATE}" ]] || die "Vorlage fehlt: ${TEMPLATE}"
  local inhalt lan_sites
  inhalt="$(cat "${TEMPLATE}")"
  lan_sites="$(render_lan_sites)"
  inhalt="${inhalt//__HOMEPAGE_UPSTREAM__/${HOMEPAGE_UPSTREAM}}"
  inhalt="${inhalt//__GRAFANA_UPSTREAM__/${GRAFANA_UPSTREAM}}"
  inhalt="${inhalt//__DOZZLE_UPSTREAM__/${DOZZLE_UPSTREAM}}"
  inhalt="${inhalt//__LITELLM_UPSTREAM__/${LITELLM_UPSTREAM}}"
  inhalt="${inhalt//__DIRECT_LLM_UPSTREAM__/${DIRECT_LLM_UPSTREAM}}"
  inhalt="${inhalt//__LAN_DOMAIN__/${LAN_DOMAIN}}"
  inhalt="${inhalt//__LAN_SITES__/${lan_sites}}"
  # Zeilenumbrueche am Dateiende entfernen: die Vorlage endet mit der
  # LAN-Zeile, und ohne LAN waeren es leere Zeilen zu viel (caddy fmt meldet das).
  while [[ "${inhalt}" == *$'\n' ]]; do inhalt="${inhalt%$'\n'}"; done
  printf '%s\n' "${inhalt}"
}

render_quadlet() {
  # Bedingungen nur aus der Konfiguration, nie aus dem laufenden Zustand:
  # make drift vergleicht diese Ausgabe mit der committeten Datei.
  local ip
  local -a netze=() netz_after=() veroeffentlichungen=()
  netze+=('Network=llm-observability.network')
  netz_after+=('llm-observability-network.service')
  if (( ${lan_enabled} == 1 )); then
    # litellm loest nur in llm-inference auf; ohne dieses Netz waere die Gateway-Route taub.
    netze+=('Network=llm-inference.network')
    netz_after+=('llm-inference-network.service')
  fi
  veroeffentlichungen+=('PublishPort=127.0.0.1:443:443')
  for ip in "${LAN_IPS[@]}"; do
    veroeffentlichungen+=("PublishPort=${ip}:443:443")
  done

  cat <<UNIT
# GENERIERT von scripts/74-setup-local-proxy.sh - dort ändern, nicht hier.
[Unit]
Description=LLM Infrastructure HTTPS-Proxy (Caddy) fuer Loopback und LAN
After=$(IFS=' '; echo "${netz_after[*]}") homepage.service grafana.service dozzle.service litellm.service
Wants=$(IFS=' '; echo "${netz_after[*]}")

[Container]
Image=docker.io/library/caddy:2-alpine
ContainerName=llm-proxy
$(printf '%s\n' "${netze[@]}")
$(printf '%s\n' "${veroeffentlichungen[@]}")
Volume=%h/.local/share/llm-infra/caddy/data:/data:Z,U
Volume=%h/.local/share/llm-infra/caddy/config:/config:Z,U
Volume=@CONFIG_ROOT@/config/proxy/Caddyfile:/etc/caddy/Caddyfile:Z,ro
Volume=@CONFIG_ROOT@/config/proxy/site:/srv/llm-proxy/site:Z,ro
UNIT
  if (( ${lan_enabled} == 1 )); then
    printf 'EnvironmentFile=%%h/.config/llm-infra/proxy/lan-auth.env\n'
  fi
  cat <<'UNIT'

[Service]
Restart=on-failure
RestartSec=15
# Schonendes Neuladen ohne Container-Neustart: systemd ruft podman auf dem Host
# auf, caddy laedt die Konfiguration im Container neu (Admin-API auf Loopback).
# Ohne diese Zeile haette "systemctl --user reload" keine ExecReload und der
# Generator wuerde bei jeder Konfigurationsaenderung den Container neu starten.
ExecReload=/usr/bin/podman exec llm-proxy caddy reload --config /etc/caddy/Caddyfile

[Install]
WantedBy=default.target
UNIT
}

write_if_changed() {
  # write_if_changed <datei> <quelle-auf-stdout>  -> 0 wenn geschrieben, 1 wenn gleich
  local ziel="$1" tmp
  tmp="$(mktemp)"
  cat > "${tmp}"
  if [[ -f "${ziel}" ]] && cmp -s "${tmp}" "${ziel}"; then
    rm -f "${tmp}"; return 1
  fi
  install -d -m 0755 "$(dirname -- "${ziel}")"
  install -m 0644 "${tmp}" "${ziel}"
  rm -f "${tmp}"; return 0
}

render_files() {
  # Nur Dateien schreiben (Pfad von make drift): kein podman, kein systemctl.
  local changed=0
  render_caddyfile | write_if_changed "${RENDERED}" && { log "Caddyfile gerendert: ${RENDERED}"; changed=1; }
  render_quadlet | write_if_changed "${QUADLET}" && { log "Quadlet geschrieben: ${QUADLET}"; changed=1; }
  [[ "${changed}" == 0 ]] && log 'Caddyfile und Quadlet sind aktuell'
  return 0
}

validate_caddyfile() {
  need_cmd podman 'Jetzt ausführen: make install'
  podman image exists "${CADDY_IMAGE}" \
    || die "Bild fehlt: ${CADDY_IMAGE} - zuerst: podman pull ${CADDY_IMAGE} (wie wiki.container es nutzt)"
  local -a opts=()
  # Die {env.*}-Platzhalter der Basic-Auth-Routen muss Caddy beim Pruefen sehen,
  # sonst meldet es "username and password are required" statt eines echten Fehlers.
  if (( ${lan_enabled} == 1 )); then
    [[ -f "${AUTH_ENV_FILE}" ]] || die "Zugangsdatei fehlt: ${AUTH_ENV_FILE} - zuerst ausrollen: ./scripts/74-setup-local-proxy.sh"
    opts+=(--env-file "${AUTH_ENV_FILE}")
  fi
  podman run --rm "${opts[@]}" -v "${RENDERED}:/etc/caddy/Caddyfile:ro" "${CADDY_IMAGE}" \
    caddy validate --adapter caddyfile --config /etc/caddy/Caddyfile
}

new_password() {
  # 24 Zeichen aus [A-Za-z0-9]: gut abtippbar auf einem zweiten Geraet.
  local roh
  roh="$(dd if=/dev/urandom bs=64 count=1 2>/dev/null | base64 | tr -d '+/=\n')"
  printf '%s' "${roh:0:24}"
}

caddy_hash() {
  # caddy_hash <klartext> -> bcrypt-Hash. Der Klartext lebt nur in einer Variable
  # dieser Shell und taucht in keiner Protokolldatei auf.
  podman run --rm --entrypoint caddy "${CADDY_IMAGE}" hash-password --plaintext "$1" 2>/dev/null \
    | tail -n 1 | tr -d '[:space:]'
}

auth_set_var() {
  # auth_set_var <VAR> <wert> - schreibt eine Zeile in die Caddy-Zugangsdatei (0600).
  local var="$1" wert="$2" tmp
  tmp="$(mktemp)"
  [[ -f "${AUTH_ENV_FILE}" ]] && grep -v "^${var}=" "${AUTH_ENV_FILE}" > "${tmp}" || true
  printf '%s=%s\n' "${var}" "${wert}" >> "${tmp}"
  install -d -m 0700 "${AUTH_DIR}"
  install -m 0600 "${tmp}" "${AUTH_ENV_FILE}"
  rm -f "${tmp}"
}

drop_var() {
  # drop_var <datei> <VAR> - Zeile entfernen (fuer erneutes Erzeugen eines Zugangs).
  local datei="$1" var="$2" tmp
  [[ -f "${datei}" ]] || return 0
  grep -q "^${var}=" "${datei}" || return 0
  tmp="$(mktemp)"
  grep -v "^${var}=" "${datei}" > "${tmp}" || true
  install -m 0600 "${tmp}" "${datei}"
  rm -f "${tmp}"
}

cred_set_var() {
  # cred_set_var <VAR> <wert> - schreibt eine Zeile in die Betreiberdatei (0600).
  local var="$1" wert="$2" tmp
  tmp="$(mktemp)"
  [[ -f "${CRED_FILE}" ]] && grep -v "^${var}=" "${CRED_FILE}" > "${tmp}" || true
  printf '%s=%s\n' "${var}" "${wert}" >> "${tmp}"
  install -d -m 0700 "${AUTH_DIR}"
  install -m 0600 "${tmp}" "${CRED_FILE}"
  rm -f "${tmp}"
}

ensure_auth_file() {
  # Idempotent: vorhandene Hashes bleiben erhalten, fehlende werden erzeugt.
  (( ${lan_enabled} == 1 )) || return 0
  need_cmd podman 'Jetzt ausführen: make install'
  install -d -m 0700 "${AUTH_DIR}"
  [[ -f "${AUTH_ENV_FILE}" ]] || { : > "${AUTH_ENV_FILE}"; chmod 0600 "${AUTH_ENV_FILE}"; }
  [[ -f "${CRED_FILE}" ]]     || { : > "${CRED_FILE}";     chmod 0600 "${CRED_FILE}"; }

  local eintrag var_user var_hash benutzer klartext hash
  for eintrag in "LLM_LAN_DOZZLE_USER:LLM_LAN_DOZZLE_HASH:${LAN_DOZZLE_USER}" \
                 "LLM_LAN_DIRECT_LLM_USER:LLM_LAN_DIRECT_LLM_HASH:${LAN_DIRECT_LLM_USER}"; do
    var_user="${eintrag%%:*}"
    var_hash="${eintrag#*:}"; var_hash="${var_hash%%:*}"
    benutzer="${eintrag##*:}"
    [[ -n "${benutzer}" ]] || die "Benutzername fuer ${var_user} ist leer - LAN_DOZZLE_USER bzw. LAN_DIRECT_LLM_USER in config/host.env setzen"
    # Namen der Datei anpassen: ein geänderter Benutzer in config/host.env gehört
    # zu einem neuen Zugang, sonst würde der alte Hash mit einem neuen Namen weiterlaufen.
    local gespeichert
    gespeichert="$(grep -m1 "^${var_user}=" "${AUTH_ENV_FILE}" 2>/dev/null | cut -d= -f2- || true)"
    if [[ -n "${gespeichert}" && "${gespeichert}" != "${benutzer}" ]]; then
      log "Benutzername fuer ${var_user} geaendert (${gespeichert} -> ${benutzer}) - Zugang wird neu erzeugt"
      drop_var "${AUTH_ENV_FILE}" "${var_hash}"
      drop_var "${CRED_FILE}" "${var_hash%_HASH}_PASSWORD"
    fi
    auth_set_var "${var_user}" "${benutzer}"
    grep -q "^${var_hash}=" "${AUTH_ENV_FILE}" && continue
    klartext="$(new_password)"
    hash="$(caddy_hash "${klartext}")"
    [[ "${hash}" == '$2'* ]] || die "Caddy erzeugte keinen bcrypt-Hash (Bild ${CADDY_IMAGE}). Nachfahren: podman run --rm ${CADDY_IMAGE} caddy hash-password --plaintext test"
    auth_set_var "${var_hash}" "${hash}"
    # Rollenweise ablegen (LLM_LAN_DOZZLE_PASSWORD, LLM_LAN_DIRECT_LLM_PASSWORD):
    # beide Routen duerften denselben Benutzernamen tragen, und ein Schluessel
    # "benutzer=wert" waere dann nicht eindeutig. Der Klartext bleibt hier, damit
    # der Betreiber ihn abtippen kann; in Git landet er nie.
    cred_set_var "${var_hash%_HASH}_PASSWORD" "${klartext}"
    log "Zugang erzeugt: ${benutzer} (${var_hash}) - Wert steht in ${CRED_FILE} (0600, nicht in Git)"
  done
}

lan_password_fuer() {
  # lan_password_fuer <VAR-des-Benutzers> -> "benutzer:klartext" fuer --check.
  local var="$1" benutzer klartext
  benutzer="$(grep -m1 "^${var}=" "${AUTH_ENV_FILE}" 2>/dev/null | cut -d= -f2- || true)"
  [[ -n "${benutzer}" ]] || return 1
  klartext="$(grep -m1 "^${var%_USER}_PASSWORD=" "${CRED_FILE}" 2>/dev/null | cut -d= -f2- || true)"
  [[ -n "${klartext}" ]] || return 1
  printf '%s:%s' "${benutzer}" "${klartext}"
}

ensure_sysctl() {
  [[ "${LLM_DRIFT:-0}" == '1' ]] && return 0
  local cur
  cur="$(sysctl -n "${SYSCTL_KEY}" 2>/dev/null || echo 1024)"
  if (( cur <= SYSCTL_WANT )); then
    log "${SYSCTL_KEY}=${cur} - Veröffentlichen von 443 als Benutzer ist möglich"
    return 0
  fi
  log "Kernelgrenze ${cur} blockiert 443 fuer rootless - senke auf ${SYSCTL_WANT} (Datei: ${SYSCTL_FILE})"
  if ! printf 'net.ipv4.ip_unprivileged_port_start=%d\n' "${SYSCTL_WANT}" | sudo -n tee "${SYSCTL_FILE}" >/dev/null; then
    die "sudo ohne Passwort moeglich? Sonst einmal von Hand:
  printf 'net.ipv4.ip_unprivileged_port_start=443' | sudo tee ${SYSCTL_FILE}
  sudo sysctl -w net.ipv4.ip_unprivileged_port_start=443
danach erneut: ./scripts/74-setup-local-proxy.sh"
  fi
  sudo -n sysctl -w "${SYSCTL_KEY}=${SYSCTL_WANT}" >/dev/null
  log "Grenze auf ${SYSCTL_WANT} gesenkt (entfernen: sudo rm ${SYSCTL_FILE} && sudo sysctl --system)"
}

lan_allowed_hosts_ok() {
  # Das Portal prueft den Host-Header: der LAN-Name muss in HOMEPAGE_ALLOWED_HOSTS stehen.
  (( ${lan_enabled} == 1 )) || return 0
  local erwartet="homepage.${LAN_DOMAIN}"
  case ",${HOMEPAGE_ALLOWED_HOSTS:-}," in
    *",${erwartet},"*|*",${erwartet}:443,"*) return 0 ;;
    *) return 1 ;;
  esac
}

plan_all() {
  printf 'Konfiguration (config/host.env)\n'
  printf '  LAN_DOMAIN       %s\n' "${LAN_DOMAIN}"
  printf '  LAN_BIND_IPS     %s\n' "${LAN_BIND_IPS:-<leer: Zugang nur auf diesem Rechner>}"
  printf '  Basic-Auth       dozzle=%s  direct-llm=%s\n' "${LAN_DOZZLE_USER}" "${LAN_DIRECT_LLM_USER}"
  printf '  vLLM-Ziel        %s\n' "${DIRECT_LLM_UPSTREAM}"
  printf '  Zugangsdatei     %s %s\n' "${AUTH_ENV_FILE}" \
    "$([[ -f ${AUTH_ENV_FILE} ]] && echo '(vorhanden, Hashes bleiben erhalten)' || echo '(fehlt - wird beim Ausrollen erzeugt)')"
  printf '\nCaddyfile: committete Datei gegen Vorlage\n'
  diff -u "${RENDERED}" <(render_caddyfile) | sed 's/^/  /' | head -80 || true
  printf '\nQuadlet: committete Datei gegen Generator\n'
  diff -u "${QUADLET}" <(render_quadlet) | sed 's/^/  /' | head -60 || true
  printf '\nInstallierte Unit gegen Repo-Stand\n'
  if installed_unit_diff "${UNIT}" >/dev/null; then
    printf '  identisch - apply kommt ohne Neustart aus\n'
  else
    printf '  Abweichung - apply startet llm-proxy.service neu (Port, Netz oder Umgebung)\n'
  fi
  lan_allowed_hosts_ok || printf '\nNoch zu tun: HOMEPAGE_ALLOWED_HOSTS um homepage.%s ergaenzen\n' "${LAN_DOMAIN}"
  printf '\nAnwenden: ./scripts/74-setup-local-proxy.sh   (oder: make local-proxy)\n'
}

apply_all() {
  need_cmd podman 'Jetzt ausführen: make install'
  if [[ "${LLM_DRIFT:-0}" == '1' ]]; then
    # Prueflauf: nur Dateien erzeugen. lib/units.sh kapselt ohnehin systemctl und
    # die Unit-Ablage; dieser Zweig haelt ausserdem sudo und podman-Aufrufe fern.
    render_files
    return 0
  fi
  ensure_auth_file
  render_files
  validate_caddyfile || die "Caddyfile ist ungueltig - nichts ausgerollt"
  install -d -m 0755 "${CADDY_HOME}/data" "${CADDY_HOME}/config" "${CA_DIR}"
  ensure_sysctl
  # Aenderungserkennung fuer den Restart: war die Unit schon in Betrieb und hat
  # sich ihre Konfiguration gerade geaendert?
  local was_active=0
  local unit_changed=0
  unit_is_active "${UNIT}" && was_active=1
  if [[ -f "${UNIT_DIR}/${UNIT}" ]] && ! installed_unit_diff "${UNIT}" >/dev/null; then
    unit_changed=1
  fi
  render_unit "${UNIT}"
  systemd_reload
  if [[ "${was_active}" == 1 ]]; then
    if [[ "${unit_changed}" == 1 ]]; then
      # Port-, Netz- und EnvironmentFile-Zeilen knuepfen podman an, nicht Caddy:
      # ein Reload ueber die Admin-API reicht dafuer nicht.
      systemctl --user restart llm-proxy.service
      log 'Proxy neu gestartet (Port-, Netzwerk- oder Umgebungskonfiguration geaendert)'
    elif systemctl --user reload llm-proxy.service 2>/dev/null; then
      log 'Proxy neu geladen (schonend ueber Admin-API)'
    else
      systemctl --user restart llm-proxy.service
      log 'Proxy neu gestartet (Reload nicht verfuegbar)'
    fi
  else
    start_units "${UNIT}"
    systemctl --user enable --now llm-proxy.service >/dev/null 2>&1 || true
  fi
  log 'Loopback-Zugang'
  log '  https://homepage.localhost/         Portal'
  log '  https://grafana.localhost/grafana/  Grafana (ohne Anmeldung, Unterpfad bleibt)'
  if (( ${lan_enabled} == 1 )); then
    log "LAN-Zugang auf ${LAN_IPS[*]} Port 443 (Rechnername ${LAN_DOMAIN})"
    log "  https://homepage.${LAN_DOMAIN}/          Portal"
    log "  https://grafana.${LAN_DOMAIN}/grafana/   Grafana (anonymes Lesen)"
    log "  https://littlem.${LAN_DOMAIN}/v1/models  Gateway (Schluessel noetig)"
    log "  https://dozzle.${LAN_DOMAIN}/            Container-Logs (Basic-Auth)"
    lan_allowed_hosts_ok || log "Noch zuruecksetzen: HOMEPAGE_ALLOWED_HOSTS um homepage.${LAN_DOMAIN} ergaenzen, dann make homepage && systemctl --user restart homepage.service"
    log "Zugangsdaten (0600, nicht in Git): ${CRED_FILE}"
    log 'Windows-Client vorbereiten:  ./scripts/74-setup-local-proxy.sh --print-hosts   und   --ca-export'
  else
    log 'LAN ist zu (LAN_BIND_IPS in config/host.env ist leer) - Zugang nur auf diesem Rechner.'
  fi
  if [[ ! -f "${CA_FILE}" ]] || ! ca_im_systemtrust; then
    log 'Noch ohne Vertrauen: ./scripts/74-setup-local-proxy.sh --ca-import  (sudo, nur dieser Rechner)'
  fi
  log 'Pruefen:            ./scripts/74-setup-local-proxy.sh --check'
}

ca_im_systemtrust() {
  have trust || return 1
  local ausgabe
  ausgabe="$(trust list --filter=ca-anchors 2>/dev/null || true)"
  [[ "${ausgabe}" == *'Caddy Local Authority'* ]]
}

extract_ca() {
  unit_is_active "${UNIT}" || die "llm-proxy.service laeuft nicht - zuerst: ./scripts/74-setup-local-proxy.sh"
  install -d -m 0755 "${CA_DIR}"
  local tmp
  tmp="$(mktemp)"
  if ! podman exec llm-proxy cat /data/caddy/pki/authorities/local/root.crt > "${tmp}" 2>/dev/null || [[ ! -s "${tmp}" ]]; then
    rm -f "${tmp}"
    die "Kein lokales CA-Zertifikat im Container - caddy hat die interne CA noch nicht angelegt. Naechster Schritt: kurz http(s)-Anfrage stellen (curl -k https://homepage.localhost/) und erneut --ca-import"
  fi
  have openssl && openssl x509 -in "${tmp}" -noout -subject >/dev/null \
    || { rm -f "${tmp}"; die "Heruntergeladene Datei ist kein lesbares PEM-Zertifikat"; }
  install -m 0644 "${tmp}" "${CA_FILE}"
  rm -f "${tmp}"
  log "CA gespeichert: ${CA_FILE} (Subject: $(openssl x509 -in "${CA_FILE}" -noout -subject 2>/dev/null | cut -c1-80))"
}

ca_import() {
  need_cmd trust 'Jetzt ausführen: sudo pacman -S p11-kit (Vertrauenswerkzeug, wie in 72-setup-opencode.py)'
  extract_ca
  if ca_im_systemtrust; then
    log "Caddy-CA ist bereits im Systemtrust"
    return 0
  fi
  sudo -n trust anchor --store "${CA_FILE}" \
    || die "trust anchor --store ${CA_FILE} schlug fehl - sudo -n pruefen und von Hand nachholen"
  have update-ca-trust && sudo -n update-ca-trust
  log 'Caddy-CA im Systemtrust verankert (curl ohne -k und Browser ohne Warnung)'
  log "Entfernen: sudo trust anchor --remove ${CA_FILE}"
}

ca_export() {
  extract_ca
  log 'Diese Datei auf den Windows-PC uebertragen, zum Beispiel:'
  log "  scp ${CA_FILE} <nutzer>@<windows-pc>:C:/temp/"
  log 'Windows 11, PowerShell als Administrator:'
  log '  certutil -addstore -f ROOT C:\temp\caddy-local-authority-root.crt'
  log 'oder im Dialog: Datei doppelklicken -> "Zertifikat installieren" -> "Lokaler Computer"'
  log '  -> Speicher "Vertrauenswuerdige Stammzertifizierungsstellen".'
  log 'Pruefung auf Windows (nach den hosts-Einträgen aus --print-hosts):'
  log "  curl.exe -s -o NUL -w \"%{http_code}\" https://homepage.${LAN_DOMAIN}/   muss 200 liefern, ohne -k"
  log 'Gegenpruefung des Fingerprints (hier auf dem Linux-Rechner ausgeben, auf Windows vergleichen):'
  have openssl && log "  openssl x509 -in ${CA_FILE} -noout -fingerprint -sha256"
  log 'Der oeffentliche Zugang der Kollegen bleibt unangetastet: TLS endet dort auf der'
  log 'Gateway-VM (docs/gateway-proxy.md). Dieses Zertifikat gilt nur im LAN.'
  log "Entfernen auf Windows:  certutil -delstore ROOT \"Caddy Local Authority\""
}

print_hosts() {
  (( ${lan_enabled} == 1 )) || die 'LAN ist zu (LAN_BIND_IPS in config/host.env ist leer) - nichts auszugeben.'
  local namen ip
  namen="$(lan_hosts | tr '\n' ' ' | sed 's/ *$//')"
  ip="${LAN_IPS[0]}"
  printf '# %s - fuer C:\\Windows\\System32\\drivers\\etc\\hosts auf dem Windows-PC\n' "$(date -Is)"
  printf '# PowerShell als Administrator:\n'
  printf '#   Add-Content -Encoding ascii C:\\Windows\\System32\\drivers\\etc\\hosts "%s %s"\n' "${ip}" "${namen}"
  printf '#\n'
  printf '%s %s\n' "${ip}" "${namen}"
}

lan_credential_path() {
  printf 'Caddy-Zugangsdatei (bcrypt-Hashes): %s\n' "${AUTH_ENV_FILE}"
  printf 'Betreiberdatei (lesbare Zugangsdaten): %s\n' "${CRED_FILE}"
  if [[ -f "${CRED_FILE}" ]]; then
    printf 'Rollen: %s\n' "$(grep -oE '^LLM_LAN_[A-Z_]+_PASSWORD' "${CRED_FILE}" | sed 's/^LLM_LAN_//; s/_PASSWORD$//' | tr '\n' ' ')"
    printf 'Die Werte selbst werden hier nicht ausgegeben - ansehen: cat %s\n' "${CRED_FILE}"
  else
    printf 'Noch keine Zugangsdaten - ausrollen: ./scripts/74-setup-local-proxy.sh\n'
  fi
}

check_all() {
  rc=0
  local tmp
  tmp="$(mktemp)"
  render_caddyfile > "${tmp}"
  cmp -s "${tmp}" "${RENDERED}" || { printf 'FEHLT: %s weicht von der Vorlage ab - 74-setup-local-proxy.sh ausführen\n' "${RENDERED}"; rc=1; }
  render_quadlet > "${tmp}"
  cmp -s "${tmp}" "${QUADLET}" || { printf 'FEHLT: %s weicht vom Generator ab\n' "${QUADLET}"; rc=1; }
  rm -f "${tmp}"
  unit_is_active "${UNIT}" || { printf 'FEHLT: llm-proxy.service laeuft nicht (journalctl --user -u llm-proxy.service -n 80)\n'; rc=1; }
  ss -tln 2>/dev/null | grep -q '127\.0\.0\.1:443 ' || { printf 'FEHLT: kein Listener auf 127.0.0.1:443\n'; rc=1; }
  local ca_opt=(-k) ca_hint='(ohne -k mit: ./scripts/74-setup-local-proxy.sh --ca-import)'
  [[ -f "${CA_FILE}" ]] && ca_opt=(--cacert "${CA_FILE}")
  local code
  code="$(curl -s -o /dev/null -m 15 "${ca_opt[@]}" -w '%{http_code}' https://homepage.localhost/ || echo 000)"
  [[ "${code}" == "200" ]] || { printf 'FEHLT: https://homepage.localhost/ liefert %s statt 200 %s\n' "${code}" "${ca_hint}"; rc=1; }
  code="$(curl -s -o /dev/null -m 15 "${ca_opt[@]}" -w '%{http_code}' https://grafana.localhost/grafana/ || echo 000)"
  [[ "${code}" == "200" ]] || { printf 'FEHLT: https://grafana.localhost/grafana/ liefert %s statt 200 %s\n' "${code}" "${ca_hint}"; rc=1; }
  if curl -sI -m 15 "${ca_opt[@]}" https://grafana.localhost/grafana/ | grep -qi 'location:.*azure'; then
    printf 'FEHLT: Grafana leitet auf die Gateway-Adresse um (301/302 auf azure)\n'; rc=1
  fi
  if ca_im_systemtrust; then
    code="$(curl -s -o /dev/null -m 15 -w '%{http_code}' https://homepage.localhost/ || echo 000)"
    [[ "${code}" == "200" ]] || { printf 'FEHLT: Systemtrust sagt nein (curl ohne -k liefert %s)\n' "${code}"; rc=1; }
  else
    printf 'HINWEIS: Caddy-CA nicht im Systemtrust - ./scripts/74-setup-local-proxy.sh --ca-import\n'
  fi
  check_backend_ports
  if (( ${lan_enabled} == 1 )); then
    check_lan
  else
    printf 'HINWEIS: LAN ist zu (LAN_BIND_IPS in config/host.env leer) - nur Loopback geprueft\n'
  fi
  [[ "${rc}" == 0 ]] && printf 'OK: HTTPS-Zugang ist erreichbar, die Backend-Ports bleiben am Loopback\n'
  return "${rc}"
}

check_backend_ports() {
  # "Keine Backend-Ports direkt veroeffentlichen": jeder Port der Liste darf
  # ausschliesslich auf dem Loopback lauschen. Fund ausserhalb = Fehler.
  local port laeuscher
  laeuscher="$(ss -tlnH 2>/dev/null | awk '{print $4}' || true)"
  for port in "${LOOPBACK_ONLY_PORTS[@]}"; do
    local fremd
    fremd="$(printf '%s\n' "${laeuscher}" | grep -E ":${port}\$" | grep -vE '^(127\.|\[::1\]|::1)' || true)"
    [[ -z "${fremd}" ]] || { printf 'FEHLT: Port %s lauscht ausserhalb des Loopback: %s\n' "${port}" "${fremd}"; rc=1; }
  done
}

lan_curl() {
  # lan_curl <vorname> <pfad> [benutzer:klartext]  -> HTTP-Code
  local vorname="$1" pfad="$2" creds="${3:-}" code
  local -a args=(-s -o /dev/null -m 20 "${ca_opt[@]}" --resolve "${vorname}.${LAN_DOMAIN}:443:${LAN_IPS[0]}" -w '%{http_code}')
  [[ -n "${creds}" ]] && args+=(-u "${creds}")
  # Bei TLS-Abbruch liefert curl 000 im Formatstring und geht mit Fehler raus -
  # ohne das "|| code=000" hier stünde dann "000000" in der Variable.
  curl "${args[@]}" "https://${vorname}.${LAN_DOMAIN}${pfad}" 2>/dev/null || code='000'
}

check_lan() {
  # Prueft den LAN-Zugang so, wie ein Windows-Client ihn benutzt: Name + Port 443
  # auf der LAN-Adresse. --resolve erspart hier die hosts-Datei auf diesem Rechner.
  local ip var host pfad code erwartet creds lan_rc=0
  for ip in "${LAN_IPS[@]}"; do
    # Erste Frage vor dem Listener: gehoert die Adresse ueberhaupt zu diesem
    # Rechner? Ein Tippfehler in LAN_BIND_IPS aeussert sich sonst nur als
    # "lauscht nicht", was nach einem Unit-Fehler aussieht.
    if ! ip -4 -o addr show scope global 2>/dev/null | grep -qE "[[:space:]]${ip}/"; then
      printf 'FEHLT: %s ist auf diesem Rechner nicht konfiguriert - LAN_BIND_IPS in config/host.env pruefen (ip -4 addr zeigen)\n' "${ip}"
      rc=1; lan_rc=1; continue
    fi
    ss -tlnH 2>/dev/null | grep -q "${ip}:443 " || { printf 'FEHLT: kein Listener auf %s:443 (llm-proxy.service neu starten)\n' "${ip}"; rc=1; lan_rc=1; }
  done
  for var in LLM_LAN_DOZZLE_USER LLM_LAN_DOZZLE_HASH LLM_LAN_DIRECT_LLM_USER LLM_LAN_DIRECT_LLM_HASH; do
    grep -q "^${var}=.\\+" "${AUTH_ENV_FILE}" 2>/dev/null \
      || { printf 'FEHLT: %s fehlt oder ist leer in %s - ausrollen: ./scripts/74-setup-local-proxy.sh\n' "${var}" "${AUTH_ENV_FILE}"; rc=1; lan_rc=1; }
  done
  if ! lan_allowed_hosts_ok; then
    printf 'FEHLT: homepage.%s fehlt in HOMEPAGE_ALLOWED_HOSTS (config/host.env)\n' "${LAN_DOMAIN}"
    printf '       Nachziehen und dann: make homepage && systemctl --user restart homepage.service\n'
    rc=1; lan_rc=1
  fi
  for host in homepage grafana littlem llm-direct; do
    case "${host}" in
      homepage) pfad='/' ;;
      grafana)  pfad='/grafana/' ;;
      *)        pfad='/v1/models' ;;
    esac
    code="$(lan_curl "${host}" "${pfad}")"
    case "${host}" in
      littlem|llm-direct) erwartet='200 oder 401'
        [[ "${code}" == "200" || "${code}" == "401" ]] || { printf 'FEHLT: https://%s.%s%s liefert %s statt 200/401\n' "${host}" "${LAN_DOMAIN}" "${pfad}" "${code}"; rc=1; lan_rc=1; } ;;
      *) erwartet=200
        [[ "${code}" == "200" ]] || { printf 'FEHLT: https://%s.%s%s liefert %s statt 200\n' "${host}" "${LAN_DOMAIN}" "${pfad}" "${code}"; rc=1; lan_rc=1; } ;;
    esac
  done
  # Basic-Auth-Routen: ohne Zugangswerte 401, mit Zugangswerten 200.
  for host in dozzle direct-llm; do
    pfad='/'
    [[ "${host}" == 'direct-llm' ]] && pfad='/v1/models'
    code="$(lan_curl "${host}" "${pfad}")"
    [[ "${code}" == "401" ]] || { printf 'FEHLT: https://%s.%s%s ohne Zugangswerte liefert %s statt 401\n' "${host}" "${LAN_DOMAIN}" "${pfad}" "${code}"; rc=1; lan_rc=1; }
    if creds="$(lan_password_fuer "LLM_LAN_$(printf '%s' "${host}" | tr '[:lower:]' '[:upper:]' | tr '-' '_')_USER")"; then
      code="$(lan_curl "${host}" "${pfad}" "${creds}")"
      [[ "${code}" == "200" ]] || { printf 'FEHLT: https://%s.%s%s mit Zugangswerten liefert %s statt 200\n' "${host}" "${LAN_DOMAIN}" "${pfad}" "${code}"; rc=1; lan_rc=1; }
    else
      printf 'FEHLT: keine Zugangswerte fuer %s in %s\n' "${host}" "${CRED_FILE}"; rc=1; lan_rc=1
    fi
  done
  # Unbekannter Name: der Fallback antwortet, aber kein Backend.
  # Mit -k geprueft: fuer einen unbekannten Namen stellt Caddy kein passende
  # Zertifikat aus; ein Abbruch der TLS-Verbindung (000) ist dasselbe Ergebnis wie
  # 403 - keineswegs ein Weiterreichen an ein Backend. Beides ist akzeptiert.
  code="$(curl -s -o /dev/null -m 20 -k --resolve "kein-host.${LAN_DOMAIN}:443:${LAN_IPS[0]}" -w '%{http_code}' https://kein-host.${LAN_DOMAIN}/ 2>/dev/null)" || code='000' 
  [[ "${code}" =~ ^(000|403)$ ]] || { printf 'FEHLT: unbekannter Name liefert %s statt 403 (Fallback-Site fehlt?)\n' "${code}"; rc=1; lan_rc=1; }
  if [[ "${lan_rc}" == 0 ]]; then
    printf 'OK: LAN-Zugang auf %s:443 - fuenf Namen erreichbar, zwei davon mit Basic-Auth\n' "${LAN_IPS[0]}"
  fi
}

status_all() {
  printf 'Unit           %s\n' "$(systemctl --user is-active llm-proxy.service 2>&1)"
  printf 'Listener 443   %s\n' "$(ss -tlnH 2>/dev/null | awk '{print $4}' | grep -E ':443$' | tr '\n' ' ')"
  printf 'Container      %s\n' "$(podman ps --filter name=llm-proxy --format '{{.Status}}' 2>/dev/null)"
  printf 'Netze          %s\n' "$(podman inspect llm-proxy --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' 2>/dev/null)"
  printf 'LAN            %s\n' "$(( ${lan_enabled} == 1 )) && printf 'an (%s, Name %s)' "${LAN_IPS[*]}" "${LAN_DOMAIN}" || printf 'zu (LAN_BIND_IPS leer)')"
  printf 'Basic-Auth     %s\n' "$([[ -f ${AUTH_ENV_FILE} ]] && printf 'Datei %s (Benutzer: %s)' "${AUTH_ENV_FILE}" "$(cut -d= -f1 "${CRED_FILE}" 2>/dev/null | tr '\n' ' ')" || printf 'fehlt (apply erzeugen)')"
  printf 'CA-Datei       %s\n' "$([[ -f ${CA_FILE} ]] && echo vorhanden || echo fehlt)"
  printf 'Systemtrust    %s\n' "$(ca_im_systemtrust && echo verankert || echo 'NICHT verankert (sudo trust anchor --store ...)')"
  printf 'Sysctl-Grenze  %s (Ziel <= %d, Datei %s)\n' "$(sysctl -n ${SYSCTL_KEY} 2>/dev/null || echo ?)" "${SYSCTL_WANT}" "$([[ -f ${SYSCTL_FILE} ]] && echo da || echo fehlt)"
  podman logs --tail 5 llm-proxy 2>/dev/null | cut -c1-160 || true
}

case "${1:---apply}" in
  --apply)   apply_all ;;
  --render)  render_files ;;
  --plan)    plan_all ;;
  --check)   check_all ;;
  --ca-import) ca_import ;;
  --ca-export) ca_export ;;
  --print-hosts) print_hosts ;;
  --lan-credentials) lan_credential_path ;;
  --status)  status_all ;;
  *) die "Unbekannter Modus: $1 (erlaubt: --plan, --check, --render, --ca-import, --ca-export, --print-hosts, --lan-credentials, --status, kein Argument)" ;;
esac
