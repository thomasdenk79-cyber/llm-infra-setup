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
#   ./scripts/74-setup-local-proxy.sh --windows-setup  kompletter PowerShell-Block
#                                                    fuer das Windows-Notebook (Namen,
#                                                    Root, Gegenproben in einem Lauf)
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
# host.env ist eine Shell-Datei: ein Wert mit Leerzeichen ohne Anfuehrungszeichen
# (LAN_BIND_IPS=1.2.3.4 5.6.7.8) laeuft als Befehl und bricht hier mit einer
# Rohtmeldung der Shell ab. Die Ansage nennt die Abhilfe gleich mit.
if [[ -f "${root}/config/host.env" ]]; then
  source "${root}/config/host.env" \
    || die "config/host.env liesst sich nicht einlesen (siehe Zeile der Shell oben). Mehrere Adressen immer in Anfuehrungszeichen setzen: LAN_BIND_IPS=\"192.168.0.198 192.168.0.47\". Danach: ./scripts/74-setup-local-proxy.sh --plan"
fi

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
  local ip="$1" teil teile=()
  [[ "${ip}" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r -a teile <<< "${ip}"
  for teil in "${teile[@]}"; do
    (( 10#${teil} <= 255 )) || return 1
  done
  return 0
}

# --- LAN-Konfiguration (Werte in config/host.env) -----------------------------
# Alle Bedingungen stehen in dieser einen Datei. Kein Blick auf den laufenden
# Zustand (Container, Ports, Eintrage unter ~/.config): make drift vergleicht die
# gerenderten Dateien, und ein Prueflauf auf einem anderen Rechner soll dasselbe
# Ergebnis sehen wie der Ausrolllauf.
lan_domain_aus_default=0
if [[ -z "${LAN_DOMAIN:-}" ]]; then
  # Der Rechnername ist nur der Notbehelf fuer einen ersten Versuch. Wo LAN-Routen
  # entstehen, die in Git landen, wird er angesagt (siehe unten) - sonst haengen die
  # Adressen unbemerkt am Rechnernamen und aendern sich mit jedem Umbenennen.
  LAN_DOMAIN="$(hostname 2>/dev/null || echo llmhost)"
  lan_domain_aus_default=1
fi
: "${LAN_DOZZLE_USER:=operator}"
: "${LAN_DIRECT_LLM_USER:=operator}"
# Uebergangsform von 2026-11-17: die Bind-Adressen lagen zuerst in einer eigenen
# Datei unter ~/.config/llm-infra. Die Datei zaehlt nur, wenn host.env die Zeile
# ueberhaupt nicht enthaelt. Ein bewusst geleeres LAN_BIND_IPS ist die dokumentierte
# Ansage "LAN zu" (docs/status.md, Rueckweg) und darf nicht daraus zurueckgeholt
# werden - sonst bleibt der Zugang im Netz, obwohl der Betreiber ihn zugemacht hat.
if [[ ! -v LAN_BIND_IPS && -f "${LEGACY_BIND_IP_FILE}" ]]; then
  LAN_BIND_IPS="$(tr -cd '0-9.,[:space:]' < "${LEGACY_BIND_IP_FILE}")"
fi
: "${LAN_BIND_IPS:=}"
# Trenner sind Leerzeichen, Tab, Umbruch oder Komma. Ein normales `read -a` hoert am
# ersten Umbruch auf und wuerde weitere Adressen stillschweigend verlieren - die
# Veroeffentlichung fehlt dann in der Unit, ohne dass eine Meldung darauf hinweist.
LAN_IPS=()
lan_eingabe="$(printf '%s' "${LAN_BIND_IPS}" | tr -s '[:space:], ' ' ')"
read -r -d '' -a LAN_IPS <<< "${lan_eingabe}" || true
lan_enabled=0
if (( ${#LAN_IPS[@]} > 0 )); then
  lan_enabled=1
  for lan_ip in "${LAN_IPS[@]}"; do
    ist_ipv4 "${lan_ip}" || die \
      "LAN_BIND_IPS enthaelt keine gueltige IPv4: '${lan_ip}'. Setzen in ${root}/config/host.env (zum Beispiel LAN_BIND_IPS=\"192.168.0.198 192.168.0.47\"), dann: ./scripts/74-setup-local-proxy.sh --plan"
    lan_anzahl=0
    for lan_pruef in "${LAN_IPS[@]}"; do
      [[ "${lan_pruef}" == "${lan_ip}" ]] && lan_anzahl=$(( lan_anzahl + 1 ))
    done
    (( lan_anzahl <= 1 )) || die \
      "LAN_BIND_IPS enthaelt ${lan_ip} mehrfach - jede Adresse nur einmal in ${root}/config/host.env eintragen, sonst lehnt podman die doppelte Veroeffentlichung ab. Danach: ./scripts/74-setup-local-proxy.sh --plan"
  done
  [[ "${LAN_DOMAIN}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,62}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,62}[A-Za-z0-9])?)*$ ]] || die \
    "LAN_DOMAIN ist kein gueltiger Rechnername: '${LAN_DOMAIN}'. Setzen in ${root}/config/host.env, dann erneut ausfuehren."
  # Zugangsdaten: ein Name mit Leerzeichen, Gleichheitszeichen oder Umbruch wirde
  # die Zugangsdatei (KEY=WERT) zerstoeren und damit beide Basic-Auth-Routen
  # unbrauchbar machen. Lieber hier scheitern als mit einem tauben 401.
  for lan_benutzer in "${LAN_DOZZLE_USER}" "${LAN_DIRECT_LLM_USER}"; do
    [[ "${lan_benutzer}" =~ ^[A-Za-z0-9._@-]+$ ]] || die \
      "Benutzername der Basic-Auth ungueltig oder leer: '${lan_benutzer}'. Erlaubt sind Buchstaben, Zahlen und . _ @ - in LAN_DOZZLE_USER bzw. LAN_DIRECT_LLM_USER (${root}/config/host.env). Danach: ./scripts/74-setup-local-proxy.sh"
  done
  if (( ${lan_domain_aus_default} == 1 )); then
    log "LAN_DOMAIN nicht gesetzt - gerendert wird mit dem Rechnernamen '${LAN_DOMAIN}'. Feste Ansage: LAN_DOMAIN=... in ${root}/config/host.env"
  fi
fi
# Reihenfolge ist Teil der gerenderten Dateien: gleiche Reihenfolge = gleiche
# Ausgabe, und darauf vergleicht make drift.
LAN_ROLES=(homepage grafana littlem llm-direct dozzle direct-llm)
# Ports, die ausschliesslich auf dem Loopback bleiben muessen (--check). Der
# Weiterleiter-Port 30001 fehlt bewusst: er bindet den Host, damit Container im
# Inferenz-Netz die Runtime erreichen (docs/runtime.md).
LOOPBACK_ONLY_PORTS=(3000 3001 3002 3100 4000 5432 8080 9090 9093 9835 30000 3003 9100 12345 8120)

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
	# Grafana leitet auf seine root_url https://grafana.localhost/grafana/ und
	# wuerfe LAN-Besucher damit auf den Loopback-Namen zurueck, den nur dieser
	# Rechner kennt. Die Umleitung bleibt deshalb auf dem Namen der Anfrage.
	tls internal
	encode zstd gzip
	reverse_proxy ${GRAFANA_UPSTREAM} {
		header_down Location "https://grafana.localhost/" "https://{http.request.host}/"
	}
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
  #
  # Bestehende Dateien werden in ihrer INODE ueberschrieben, nicht ersetzt: der
  # Proxy haengt am Caddyfile als Einzel-Datei-Bindung. Wird die Datei ausgetauscht
  # (install, mv), sieht der Container weiter die alte Fassung und der Reload ueber
  # die Admin-API laedt stillschweigend die alten Seiten. Gemessen 2026-11-17:
  # Host-Inode 919969 (5723 B) gegen Container-Inode 918478 (5324 B).
  local ziel="$1" tmp
  tmp="$(mktemp)"
  cat > "${tmp}"
  if [[ -f "${ziel}" ]] && cmp -s "${tmp}" "${ziel}"; then
    rm -f "${tmp}"; return 1
  fi
  install -d -m 0755 "$(dirname -- "${ziel}")"
  if [[ -f "${ziel}" ]]; then
    cat "${tmp}" > "${ziel}"
    chmod 0644 "${ziel}"
  else
    install -m 0644 "${tmp}" "${ziel}"
  fi
  rm -f "${tmp}"; return 0
}

render_files() {
  # Nur Dateien schreiben (der Pfad, den make drift und --check vergleichen): kein
  # podman, kein systemctl, kein sudo. Verglichen wird das Quadlet von
  # scripts/check-drift.sh, das Caddyfile von --check in diesem Skript.
  local changed=0
  render_caddyfile | write_if_changed "${RENDERED}" && { log "Caddyfile gerendert: ${RENDERED}"; changed=1; }
  render_quadlet | write_if_changed "${QUADLET}" && { log "Quadlet geschrieben: ${QUADLET}"; changed=1; }
  [[ "${changed}" == 0 ]] && log 'Caddyfile und Quadlet sind aktuell'
  return 0
}

validate_caddyfile() {
  # validate_caddyfile <datei>  -> laesst Caddy die gerenderte Fassung pruefen,
  # BEVOR sie ins Repo geschrieben und ausgerollt wird.
  need_cmd podman 'Jetzt ausführen: make install'
  [[ -f "${1:-}" ]] || die "Zu pruefende Caddyfile fehlt: ${1:-<keine Angabe>}. Nachfahren: ./scripts/74-setup-local-proxy.sh --render"
  podman image exists "${CADDY_IMAGE}" \
    || die "Bild fehlt: ${CADDY_IMAGE} - zuerst: podman pull ${CADDY_IMAGE} (wie wiki.container es nutzt)"
  local -a opts=()
  # Die {env.*}-Platzhalter der Basic-Auth-Routen muss Caddy beim Pruefen sehen,
  # sonst meldet es "username and password are required" statt eines echten Fehlers.
  if (( ${lan_enabled} == 1 )); then
    [[ -f "${AUTH_ENV_FILE}" ]] || die "Zugangsdatei fehlt: ${AUTH_ENV_FILE} - zuerst ausrollen: ./scripts/74-setup-local-proxy.sh"
    opts+=(--env-file "${AUTH_ENV_FILE}")
  fi
  podman run --rm "${opts[@]}" -v "${1}:/etc/caddy/Caddyfile:ro" "${CADDY_IMAGE}" \
    caddy validate --adapter caddyfile --config /etc/caddy/Caddyfile
}

new_password() {
  # 24 Zeichen aus [A-Za-z0-9]: gut abtippbar auf einem zweiten Geraet.
  local roh
  roh="$(dd if=/dev/urandom bs=64 count=1 2>/dev/null | base64 | tr -d '+/=\n')" || roh=''
  (( ${#roh} >= 24 )) || die "Zufallswert aus /dev/urandom war zu kurz (${#roh} Zeichen) - dd und base64 muessen verfuegbar sein. Von Hand nachfahren: dd if=/dev/urandom bs=64 count=1 | base64 , danach erneut: ./scripts/74-setup-local-proxy.sh"
  printf '%s' "${roh:0:24}"
}

caddy_hash() {
  # caddy_hash <klartext> -> bcrypt-Hash. Der Klartext geht über die
  # Standardeingabe in den Container: als Befehlszeilenargument stünde er waehrend
  # der Laufzeit im Prozessbaum (ps, auditd, Journale) und waere damit fuer jeden
  # anderen Prozess auf dem Rechner lesbar. Die Fehlerausgabe von podman bleibt
  # sichtbar - sonst endet ein Lauf schweigend und der Betreiber raetselt.
  printf '%s' "$1" | podman run -i --rm --entrypoint caddy "${CADDY_IMAGE}" hash-password \
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
    # Ein fehlgeschlagenes podman darf nicht schweigend enden: zuweisung mit
    # Auffang, damit die Meldung unten den naechsten Befehl nennt (Regel 7).
    hash="$(caddy_hash "${klartext}")" || hash=''
    [[ "${hash}" == '$2'* ]] || die "Caddy erzeugte keinen bcrypt-Hash (Bild ${CADDY_IMAGE}, podman laeuft?). Von Hand nachfahren: printf test | podman run -i --rm --entrypoint caddy ${CADDY_IMAGE} hash-password , danach erneut: ./scripts/74-setup-local-proxy.sh"
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
  sudo -n sysctl -w "${SYSCTL_KEY}=${SYSCTL_WANT}" >/dev/null \
    || die "sysctl -w ${SYSCTL_KEY}=${SYSCTL_WANT} schlug fehl (sudo ohne Passwort?). Von Hand: sudo sysctl -w ${SYSCTL_KEY}=${SYSCTL_WANT} , danach erneut: ./scripts/74-setup-local-proxy.sh"
  log "Grenze auf ${SYSCTL_WANT} gesenkt (entfernen: sudo rm ${SYSCTL_FILE} && sudo sysctl --system)"
}

lan_allowed_hosts_ok() {
  # Das Portal prueft den Host-Header: der LAN-Name muss in HOMEPAGE_ALLOWED_HOSTS stehen.
  # Normierung wie beim Port-Generator (scripts/60-install-homepage.sh trennt ebenfalls
  # nur auf Komma und wirft vorher jeden Whitespace weg): sonst meldet --check ein
  # fehlendes Eintrag, obwohl laengst gesetzt - nur mit Leerzeichen nach dem Komma.
  # Ein '*' bedeutet "keine Pruefung" und braucht dann keinen Namen in der Liste.
  (( ${lan_enabled} == 1 )) || return 0
  local erwartet="homepage.${LAN_DOMAIN}" freigabe
  freigabe="$(printf '%s' "${HOMEPAGE_ALLOWED_HOSTS:-}" | tr -d '[:space:]')"
  [[ "${freigabe}" == '*' ]] && return 0
  case ",${freigabe}," in
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
  # Erst pruefen, dann schreiben: ein ungueltiges Caddyfile darf weder in Git
  # landen noch ausgerollt werden. Geprueft wird die gerenderte Fassung in state/.
  local kandidat="${STATE_DIR}/caddyfile-kandidat"
  install -d -m 0755 "${STATE_DIR}"
  render_caddyfile > "${kandidat}"
  if ! validate_caddyfile "${kandidat}"; then
    rm -f "${kandidat}"
    die "Caddyfile ist ungueltig - nichts ausgerollt. Vorlage pruefen: ${TEMPLATE}; von Hand nachfahren: ./scripts/74-setup-local-proxy.sh --render und dann podman-Fehler ansehen"
  fi
  rm -f "${kandidat}"
  render_files
  install -d -m 0755 "${CADDY_HOME}/data" "${CADDY_HOME}/config" "${CA_DIR}"
  ensure_sysctl
  # Aenderungserkennung fuer den Restart: war die Unit schon in Betrieb und hat
  # sich ihre Konfiguration gerade geaendert?
  local was_active=0
  local unit_changed=0
  local live_stale=0
  unit_is_active "${UNIT}" && was_active=1
  if [[ -f "${UNIT_DIR}/${UNIT}" ]] && ! installed_unit_diff "${UNIT}" >/dev/null; then
    unit_changed=1
  fi
  # Laeuft im Container eine andere Fassung als auf dem Host, reicht Reload nicht:
  # die Einzel-Datei-Bindung folgt dem Inode nicht. Der Vergleich zwingt den Weg
  # ueber einen Neustart, damit die ausgerollte Fassung wirklich ankommt.
  if [[ "${was_active}" == 1 ]] && command -v podman >/dev/null 2>&1; then
    local live host_sum
    live="$(podman exec llm-proxy sha256sum /etc/caddy/Caddyfile 2>/dev/null | awk '{print $1}')"
    host_sum="$(sha256sum "${RENDERED}" 2>/dev/null | awk '{print $1}')"
    if [[ -n "${live}" && -n "${host_sum}" && "${live}" != "${host_sum}" ]]; then
      live_stale=1
      log 'Der Container nutzt eine aeltere Caddyfile als das Repo - Noetig ist ein Neustart des Proxies.'
    fi
  fi
  render_unit "${UNIT}"
  systemd_reload
  if [[ "${was_active}" == 1 ]]; then
    if [[ "${unit_changed}" == 1 || "${live_stale}" == 1 ]]; then
      # Port-, Netz- und EnvironmentFile-Zeilen knuepfen podman an, nicht Caddy:
      # ein Reload ueber die Admin-API reicht dafuer nicht. Dasselbe gilt, wenn im
      # Container eine alte Caddyfile gebunden ist (live_stale).
      systemctl --user restart llm-proxy.service
      log 'Proxy neu gestartet (Port-, Netzwerk- oder Umgebungskonfiguration geaendert, oder Container hatte eine veraltete Caddyfile)'
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
  if have update-ca-trust; then
    sudo -n update-ca-trust || log "WARNUNG: update-ca-trust lief nicht - von Hand: sudo update-ca-trust , danach pruefen mit: trust list --filter=ca-anchors | grep -i caddy"
  fi
  log 'Caddy-CA im Systemtrust verankert (curl ohne -k und Browser ohne Warnung)'
  log "Entfernen: sudo trust anchor --remove ${CA_FILE}"
}

ca_export() {
  extract_ca
  # Der Fingerabdruck erlaubt dem Windows-Betreiber eine Aussage ueber die
  # Echtheit der uebertragenen Wurzel, bevor er sie importiert (Gegprobe:
  # certutil -dump zeigt denselben Wert).
  if command -v openssl >/dev/null 2>&1 && [[ -f "${CA_FILE}" ]]; then
    local finger
    finger="$(openssl x509 -in "${CA_FILE}" -noout -fingerprint -sha256 2>/dev/null | sed 's/^.*=//')"
    [[ -n "${finger}" ]] && log "Fingerabdruck der Wurzel (SHA-256): ${finger}"
    [[ -n "${finger}" ]] && log '  Gegprobe auf Windows:  certutil -dump C:\temp\caddy-local-authority-root.crt'
  fi
  log 'Diese Datei auf den Windows-PC uebertragen, zum Beispiel:'
  log "  scp ${CA_FILE} <nutzer>@<windows-pc>:C:/temp/"
  if (( ${lan_enabled} == 0 )); then
    # Ohne LAN gibt es keine LAN-Namen und damit nichts, was ein Windows-Client
    # eintragen koennte. Die CA ist trotzdem brauchbar - nur die Windows-Anleitung
    # waere in diesem Zustand falsch.
    log 'LAN ist zu (LAN_BIND_IPS in config/host.env ist leer) - es gibt nur die Loopback-Namen.'
    log "Pruefen auf diesem Rechner:  curl -s -o /dev/null -w '%{http_code}' --cacert ${CA_FILE} https://homepage.localhost/   muss 200 liefern"
    log 'Fuer den Windows-PC zuerst das LAN einschalten: LAN_BIND_IPS in config/host.env setzen,'
    log 'dann ausrollen und danach erneut: ./scripts/74-setup-local-proxy.sh --ca-export'
    return 0
  fi
  log 'Windows 11, PowerShell als Administrator - am einfachsten das Skript aus dem Repo'
  log "  Skript im Repo: scripts/windows-lan-client-setup.ps1 (hosts-Datei, Root-Import, alle Routen pruefen)"
  log '  Set-ExecutionPolicy -Scope Process Bypass -Force'
  log "  .\windows-lan-client-setup.ps1 -LanIp ${LAN_IPS[0]} -Domain ${LAN_DOMAIN} -CertPath C:\temp\caddy-local-authority-root.crt"
  log 'Einzelne Schritte gehen auch einzeln:'
  log '  certutil -addstore -f ROOT C:\temp\caddy-local-authority-root.crt'
  log 'oder im Dialog: Datei doppelklicken -> "Zertifikat installieren" -> "Lokaler Computer"'
  log '  -> Speicher "Vertrauenswuerdige Stammzertifizierungsstellen".'
  log 'Pruefung auf Windows (nach den hosts-Eintraegen aus --print-hosts):'
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

windows_setup() {
  # Ein einziger Block zum Einfuegen in die PowerShell des Windows-Notebooks
  # (als Administrator): Namen eintragen, Route pruefen, Wurzel holen, Fingerabdruck
  # vergleichen, importieren, alle Routen gegen die erwarteten Codes. Der Weg bis
  # hier war Handarbeit aus zwei Abschnitten - ein Versehen (Tippfehler, falscher
  # Pfad, fehlender Fingerabdruck) ist damit ausgeschlossen. Es stehen keine
  # Zugangswerte in der Ausgabe; die zwei Basic-Auth-Routen pruefen auf 401.
  (( ${lan_enabled} == 1 )) || die 'LAN ist zu (LAN_BIND_IPS in config/host.env ist leer) - nichts auszugeben.'
  extract_ca >/dev/null 2>&1 || true
  local ip namen finger basis rolle pfad erwartet
  ip="${LAN_IPS[0]}"
  namen="$(lan_hosts | tr '\n' ' ' | sed 's/ *$//')"
  basis="$(basename "${CA_FILE}")"
  finger=''
  command -v openssl >/dev/null 2>&1 && [[ -f "${CA_FILE}" ]] \
    && finger="$(openssl x509 -in "${CA_FILE}" -noout -fingerprint -sha256 2>/dev/null | sed 's/^.*=//')"
  printf '# Windows 11, PowerShell als Administrator einfügen - Rechner %s, Stand %s\n' "$(hostname)" "$(date -Is)"
  printf '# 1) Namen bekannt machen: fuer diese Namen gibt es kein DNS im Netz\n'
  printf 'Add-Content -Encoding ascii C:\\Windows\\System32\\drivers\\etc\\hosts "%s %s"\n' "${ip}" "${namen}"
  printf 'ipconfig /flushdns\n'
  printf '# 2) Route und Paketfilter pruefen (erwartet: TcpTestSucceeded : True)\n'
  printf 'Test-NetConnection %s -Port 443\n' "${ip}"
  printf '# 3) Wurzelzertifikat holen und Fingerabdruck vergleichen, dann importieren\n'
  printf 'New-Item -ItemType Directory -Force C:\\temp | Out-Null\n'
  printf 'scp %s@%s:%s C:\\temp\\\n' "$(id -un)" "${ip}" "${CA_FILE}"
  printf 'certutil -dump C:\\temp\\%s\n' "${basis}"
  [[ -n "${finger}" ]] && printf '#  muss zeigen: SHA256 %s\n' "${finger}"
  printf 'certutil -addstore -f ROOT C:\\temp\\%s\n' "${basis}"
  printf '# 4) Gegenprobe aller Routen (erwartete Codes stehen als Kommentar)\n'
  for rolle in "${LAN_ROLES[@]}"; do
    case "${rolle}" in
      homepage)      pfad='/';            erwartet='200' ;;
      grafana)       pfad='/grafana/';    erwartet='200 (die Wurzel / leitet mit 301)' ;;
      dozzle)        pfad='/';            erwartet='401 ohne Zugangswerte' ;;
      direct-llm)    pfad='/v1/models';   erwartet='401 ohne Zugangswerte' ;;
      *)             pfad='/v1/models';   erwartet='401 ohne Schluessel' ;;
    esac
    printf 'curl.exe -s -o NUL -w "%%{http_code}`n" https://%s.%s%s   # %s\n' \
      "${rolle}" "${LAN_DOMAIN}" "${pfad}" "${erwartet}"
  done
  printf '# Zugangswerte der zwei Basic-Auth-Routen (0600, nie in Git): %s\n' "${CRED_FILE}"
  printf '# Rueckbau: hosts-Zeile loeschen und certutil -delstore ROOT "Caddy Local Authority"\n'
  printf '# Mit dem Repo auf dem Notebook erledigt das Skript alles in einem Lauf:\n'
  printf '#   .\\scripts\\windows-lan-client-setup.ps1 -LanIp %s -Domain %s -CertPath C:\\temp\\%s\n' \
    "${ip}" "${LAN_DOMAIN}" "${basis}"
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

https_code() {
  # https_code <url> [weitere curl-Argumente]  -> HTTP-Code, '000' bei Abbruch.
  # curl schreibt seinen Formatstring auch bei fehlgeschlagener Verbindung (dann
  # 000) und geht mit Fehler raus. Ein zweites "|| echo 000" hinter dem Aufruf
  # haette "000000" ergeben; fehlt die Ausgabe ganz (curl nicht auffindbar), steht
  # sonst eine leere Variable in der Meldung.
  local url="$1"; shift
  local ausgabe
  ausgabe="$(curl -s -o /dev/null -m 20 "$@" -w '%{http_code}' "${url}" 2>/dev/null)" || true
  [[ -n "${ausgabe}" ]] || ausgabe='000'
  printf '%s' "${ausgabe}"
}

check_all() {
  local fehlt=0
  need_cmd curl 'Jetzt ausführen: sudo pacman -S curl' || fehlt=1
  need_cmd ss   'Jetzt ausführen: sudo pacman -S iproute2' || fehlt=1
  need_cmd ip   'Jetzt ausführen: sudo pacman -S iproute2' || fehlt=1
  if (( ${fehlt} == 1 )); then
    printf 'FEHLT: Pruefwerkzeug fehlt (siehe Zeilen oben) - nachinstallieren, dann: ./scripts/74-setup-local-proxy.sh --check\n'
    return 1
  fi
  rc=0
  local tmp
  tmp="$(mktemp "${STATE_DIR}/pruefung.XXXXXX")"
  render_caddyfile > "${tmp}"
  cmp -s "${tmp}" "${RENDERED}" || { printf 'FEHLT: %s weicht von der Vorlage ab - 74-setup-local-proxy.sh ausführen\n' "${RENDERED}"; rc=1; }
  render_quadlet > "${tmp}"
  cmp -s "${tmp}" "${QUADLET}" || { printf 'FEHLT: %s weicht vom Generator ab\n' "${QUADLET}"; rc=1; }
  rm -f "${tmp}"
  # Repo und installierte Unit muessen dieselbe Sprache reden: sonst laeuft ein
  # Proxy, den kein Prueflauf des Repos beschreibt (Port, Netz, EnvironmentFile).
  installed_unit_diff "${UNIT}" >/dev/null 2>&1 \
    || { printf 'FEHLT: installierte Unit weicht von quadlet/%s ab (oder fehlt) - ausrollen: ./scripts/74-setup-local-proxy.sh\n' "${UNIT}"; rc=1; }
  # Der laufende Container muss dieselbe Fassung nutzen wie das Repo. Eine
  # Einzel-Datei-Bindung folgt keinem Inode-Wechsel,darum kann ein Reload ins
  # Leere laufen, obwohl Datei und Unit auf dem Host stimmen (siehe
  # write_if_changed). Nur der Vergleich mit dem Container deckt das auf.
  if command -v podman >/dev/null 2>&1 && unit_is_active "${UNIT}"; then
    local live host_sum
    live="$(podman exec llm-proxy sha256sum /etc/caddy/Caddyfile 2>/dev/null | awk '{print $1}')"
    host_sum="$(sha256sum "${RENDERED}" 2>/dev/null | awk '{print $1}')"
    if [[ -z "${live}" ]]; then
      printf 'FEHLT: laufende Caddyfile nicht lesbar - Container llm-proxy erreichbar? (podman ps --filter name=llm-proxy)\n'
      rc=1
    elif [[ "${live}" != "${host_sum}" ]]; then
      printf 'FEHLT: der laufende Proxy nutzt eine andere Caddyfile als die committete - der letzte Reload lief ins Leere\n'
      printf '  Jetzt ausführen: ./scripts/74-setup-local-proxy.sh   (Wenn das nicht hilft: podman restart llm-proxy)\n'
      rc=1
    fi
  fi
  unit_is_active "${UNIT}" || { printf 'FEHLT: llm-proxy.service laeuft nicht (journalctl --user -u llm-proxy.service -n 80)\n'; rc=1; }
  ss -tln 2>/dev/null | grep -q '127\.0\.0\.1:443 ' || { printf 'FEHLT: kein Listener auf 127.0.0.1:443\n'; rc=1; }
  local ca_opt=(-k) ca_hint='(ohne -k mit: ./scripts/74-setup-local-proxy.sh --ca-import)'
  [[ -f "${CA_FILE}" ]] && ca_opt=(--cacert "${CA_FILE}")
  local code
  code="$(https_code https://homepage.localhost/ "${ca_opt[@]}")"
  [[ "${code}" == "200" ]] || { printf 'FEHLT: https://homepage.localhost/ liefert %s statt 200 %s\n' "${code}" "${ca_hint}"; rc=1; }
  code="$(https_code https://grafana.localhost/grafana/ "${ca_opt[@]}")"
  [[ "${code}" == "200" ]] || { printf 'FEHLT: https://grafana.localhost/grafana/ liefert %s statt 200 %s\n' "${code}" "${ca_hint}"; rc=1; }
  if curl -sI -m 15 "${ca_opt[@]}" https://grafana.localhost/grafana/ | grep -qi 'location:.*azure'; then
    printf 'FEHLT: Grafana leitet auf die Gateway-Adresse um (301/302 auf azure)\n'; rc=1
  fi
  if ca_im_systemtrust; then
    code="$(https_code https://homepage.localhost/)"
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
  # --resolve erspart die hosts-Datei auf diesem Rechner. Bei TLS-Abbruch gibt curl
  # seinen Formatstring ('000') selbst aus und geht mit Fehler raus; fehlt die
  # Ausgabe ganz, steht sonst eine leere Variable da und die Meldung ist wertlos.
  local vorname="$1" pfad="$2" creds="${3:-}"
  local -a args=(-s -o /dev/null -m 20 "${ca_opt[@]}" --resolve "${vorname}.${LAN_DOMAIN}:443:${LAN_IPS[0]}" -w '%{http_code}')
  if [[ -n "${creds}" ]]; then args+=(-u "${creds}"); fi
  local ausgabe
  ausgabe="$(curl "${args[@]}" "https://${vorname}.${LAN_DOMAIN}${pfad}" 2>/dev/null)" || true
  [[ -n "${ausgabe}" ]] || ausgabe='000'
  printf '%s' "${ausgabe}"
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
      # Gegenprobe: ein falsches Passwort muss 401 bringen. Ohne sie bliebe ein
      # Basic-Auth-Zweig unentdeckt, der nur den Benutzernamen vergleicht.
      local falsch_code
      falsch_code="$(lan_curl "${host}" "${pfad}" "${creds%%:*}:sicher-nicht-das-passwort")"
      [[ "${falsch_code}" == '401' ]] || { printf 'FEHLT: https://%s.%s%s laesst ein falsches Passwort durch (%s) - Basic-Auth prueft nicht beide Teile\n' "${host}" "${LAN_DOMAIN}" "${pfad}" "${falsch_code}"; rc=1; lan_rc=1; }
    else
      printf 'FEHLT: keine Zugangswerte fuer %s in %s\n' "${host}" "${CRED_FILE}"; rc=1; lan_rc=1
    fi
  done
  # Unbekannter Name: der Fallback antwortet, aber kein Backend.
  # Mit -k geprueft: fuer einen unbekannten Namen stellt Caddy kein passende
  # Zertifikat aus; ein Abbruch der TLS-Verbindung (000) ist dasselbe Ergebnis wie
  # 403 - keineswegs ein Weiterreichen an ein Backend. Beides ist akzeptiert.
  code="$(https_code "https://kein-host.${LAN_DOMAIN}/" -k --resolve "kein-host.${LAN_DOMAIN}:443:${LAN_IPS[0]}")"
  [[ "${code}" =~ ^(000|403)$ ]] || { printf 'FEHLT: unbekannter Name liefert %s statt 403 (Fallback-Site fehlt?)\n' "${code}"; rc=1; lan_rc=1; }
  if [[ "${lan_rc}" == 0 ]]; then
    printf 'OK: LAN-Zugang auf %s:443 - sechs Namen geprueft, zwei davon mit Basic-Auth\n' "${LAN_IPS[0]}"
  fi
}

status_all() {
  # Kurzbild des Ist-Zustands. Die Zeilen sind Absicht in dieser Reihenfolge:
  # Unit, Listener, Netze, Zugang, Vertrauensanker, Kernelgrenze, letzte Logs.
  local lan_text basic_text benutzer
  if (( ${lan_enabled} == 1 )); then
    lan_text="an (${LAN_IPS[*]}, Name ${LAN_DOMAIN})"
  else
    lan_text='zu (LAN_BIND_IPS in config/host.env ist leer)'
  fi
  if [[ -f "${AUTH_ENV_FILE}" ]]; then
    # Nur die Benutzernamen (stehen ohnehin in config/host.env), nie die Hashes.
    benutzer="$(grep '^LLM_LAN_[A-Z_]*_USER=' "${AUTH_ENV_FILE}" 2>/dev/null | cut -d= -f2- | tr '\n' ' ' | sed 's/ *$//')"
    basic_text="Datei ${AUTH_ENV_FILE} (Benutzer: ${benutzer:-keine})"
  else
    basic_text="fehlt - ausrollen: ./scripts/74-setup-local-proxy.sh"
  fi
  printf 'Unit           %s\n' "$(systemctl --user is-active llm-proxy.service 2>&1)"
  printf 'Listener 443   %s\n' "$(ss -tlnH 2>/dev/null | awk '{print $4}' | grep -E ':443$' | tr '\n' ' ')"
  printf 'Container      %s\n' "$(podman ps --filter name=llm-proxy --format '{{.Status}}' 2>/dev/null)"
  printf 'Netze          %s\n' "$(podman inspect llm-proxy --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' 2>/dev/null)"
  printf 'LAN            %s\n' "${lan_text}"
  printf 'Basic-Auth     %s\n' "${basic_text}"
  printf 'CA-Datei       %s\n' "$([[ -f ${CA_FILE} ]] && echo vorhanden || echo fehlt)"
  printf 'Systemtrust    %s\n' "$(ca_im_systemtrust && echo verankert || echo 'NICHT verankert (sudo trust anchor --store ...)')"
  printf 'Sysctl-Grenze  %s (Ziel <= %d, Datei %s)\n' "$(sysctl -n ${SYSCTL_KEY} 2>/dev/null || echo ?)" "${SYSCTL_WANT}" "$([[ -f ${SYSCTL_FILE} ]] && echo da || echo fehlt)"
  podman logs --tail 5 llm-proxy 2>/dev/null | cut -c1-160 || true
}

# Die Drift-Kapsel aus lib/units.sh verdeckt systemctl (sonst wuerde ein Prueflauf
# den laufenden Proxy neu starten). Dieselbe Kapsel macht aber jede Pruefung blind:
# "unit_is_active" sagt dann immer ja. Pruefen und Ausgeben deshalb nur ohne Kapsel
# - make drift braucht ausschliesslich den Datei-Zweig.
if [[ "${LLM_DRIFT:-0}" == '1' ]]; then
  case "${1:---apply}" in
    --apply|--render) ;;
    *) die "LLM_DRIFT=1 ist die Kapsel von make drift und prueft nichts (systemctl ist verdeckt). Ohne die Variable ausführen: ./scripts/74-setup-local-proxy.sh ${1:---check}" ;;
  esac
fi

case "${1:---apply}" in
  --apply)   apply_all ;;
  --render)  render_files ;;
  --plan)    plan_all ;;
  --check)   check_all ;;
  --ca-import) ca_import ;;
  --ca-export) ca_export ;;
  --print-hosts) print_hosts ;;
  --windows-setup) windows_setup ;;
  --lan-credentials) lan_credential_path ;;
  --status)  status_all ;;
  *) die "Unbekannter Modus: $1 (erlaubt: --plan, --check, --render, --ca-import, --ca-export, --print-hosts, --windows-setup, --lan-credentials, --status, kein Argument)" ;;
esac
