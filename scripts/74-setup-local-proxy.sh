#!/usr/bin/env bash
# Lokaler HTTPS-Zugang ueber Namen: ein verwalteter Caddy im Netz
# llm-observability, veroeffentlicht nur auf 127.0.0.1:443.
#
#   ./scripts/74-setup-local-proxy.sh             alles einrichten (Standard)
#   ./scripts/74-setup-local-proxy.sh --check     pruefen, nichts aendern
#   ./scripts/74-setup-local-proxy.sh --render    nur Dateien schreiben (make drift)
#   ./scripts/74-setup-local-proxy.sh --ca-import Caddy-CA in den Systemtrust
#   ./scripts/74-setup-local-proxy.sh --status    Kurzbild des Ist-Zustands
#
# Was dabei entsteht:
#   1. config/proxy/Caddyfile      - gerendert aus config/proxy/Caddyfile.template
#   2. quadlet/llm-proxy.container - Unit-Datei mit Header "GENERIERT von"
#   3. die Benutzer-Unit llm-proxy.service (Netz llm-observability, 127.0.0.1:443)
#
# Zwei Sites: homepage.localhost -> Portal (llm-homepage:3000) und
# grafana.localhost -> Grafana (grafana:3000, Unterpfad /grafana/ unveraendert).
# Ziel: https://grafana.localhost/grafana/ ohne 301 auf die Gateway-Adresse.
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
UNIT='llm-proxy.container'

# Upstream-Namen: so, wie sie im Netz llm-observability aufloesen (gemessen mit
# getent in einem Wegwerf-Container). Ports sind die internen Ports der Quadlets.
HOMEPAGE_UPSTREAM='llm-homepage:3000'
GRAFANA_UPSTREAM='grafana:3000'

render_caddyfile() {
  [[ -f "${TEMPLATE}" ]] || die "Vorlage fehlt: ${TEMPLATE}"
  sed -e "s#__HOMEPAGE_UPSTREAM__#${HOMEPAGE_UPSTREAM}#" \
      -e "s#__GRAFANA_UPSTREAM__#${GRAFANA_UPSTREAM}#" \
      "${TEMPLATE}"
}

render_quadlet() {
  cat <<'UNIT'
# GENERIERT von scripts/74-setup-local-proxy.sh - dort ändern, nicht hier.
[Unit]
Description=LLM Infrastructure lokaler HTTPS-Proxy (Caddy, nur 127.0.0.1:443)
After=llm-observability-network.service homepage.service grafana.service
Wants=llm-observability-network.service

[Container]
Image=docker.io/library/caddy:2-alpine
ContainerName=llm-proxy
Network=llm-observability.network
PublishPort=127.0.0.1:443:443
Volume=%h/.local/share/llm-infra/caddy/data:/data:Z,U
Volume=%h/.local/share/llm-infra/caddy/config:/config:Z,U
Volume=@CONFIG_ROOT@/config/proxy/Caddyfile:/etc/caddy/Caddyfile:Z,ro
Volume=@CONFIG_ROOT@/config/proxy/site:/srv/llm-proxy/site:Z,ro

[Service]
Restart=on-failure
RestartSec=15

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
  render_quadlet   | write_if_changed "${QUADLET}"  && { log "Quadlet geschrieben: ${QUADLET}"; changed=1; }
  [[ "${changed}" == 0 ]] && log 'Caddyfile und Quadlet sind aktuell'
  return 0
}

validate_caddyfile() {
  need_cmd podman 'Jetzt ausführen: make install'
  podman image exists "${CADDY_IMAGE}" \
    || die "Bild fehlt: ${CADDY_IMAGE} - zuerst: podman pull ${CADDY_IMAGE} (wie wiki.container es nutzt)"
  podman run --rm -v "${RENDERED}:/etc/caddy/Caddyfile:ro" "${CADDY_IMAGE}" \
    caddy validate --adapter caddyfile --config /etc/caddy/Caddyfile
}

ensure_sysctl() {
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

apply_all() {
  need_cmd podman 'Jetzt ausführen: make install'
  local changed=0
  render_files
  # Nur pruefen, wenn gerade etwas neu geschrieben wurde oder die Unit laeuft.
  validate_caddyfile || die "Caddyfile ist ungueltig - nichts ausgerollt"
  install -d -m 0755 "${CADDY_HOME}/data" "${CADDY_HOME}/config" "${CA_DIR}"
  ensure_sysctl
  # Aenderungserkennung fuer den Restart: war die Unit schon in Betrieb und hat
  # sich ihre Konfiguration gerade geaendert?
  local was_active=0
  unit_is_active "${UNIT}" && was_active=1
  if [[ -f "${UNIT_DIR}/${UNIT}" ]] && ! installed_unit_diff "${UNIT}" >/dev/null; then
    changed=1
  fi
  render_unit "${UNIT}"
  systemd_reload
  if [[ "${was_active}" == 1 ]]; then
    # Reload reicht, weil die Admin-API im Container auf Loopback hoert; ein
    # Restart der Proxy-Unit wirft nur kurze lokale Anfragen, keine Inferenz.
    if systemctl --user reload llm-proxy.service 2>/dev/null; then
      log 'Proxy neu geladen (schonend ueber Admin-API)'
    else
      systemctl --user restart llm-proxy.service
      log 'Proxy neu gestartet (Reload nicht verfuegbar)'
    fi
  else
    start_units "${UNIT}"
    systemctl --user enable --now llm-proxy.service >/dev/null 2>&1 || true
  fi
  log 'Lokaler Zugang'
  log '  https://homepage.localhost/         Portal'
  log '  https://grafana.localhost/grafana/  Grafana (ohne Anmeldung, Unterpfad bleibt)'
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
  [[ "${rc}" == 0 ]] && printf 'OK: lokaler HTTPS-Zugang richtet sich wie vereinbart\n'
  return "${rc}"
}

status_all() {
  printf 'Unit         %s\n' "$(systemctl --user is-active llm-proxy.service 2>&1)"
  printf 'Listener 443 %s\n' "$(ss -tln 2>/dev/null | grep -c '127\.0\.0\.1:443 ')"
  printf 'Container    %s\n' "$(podman ps --filter name=llm-proxy --format '{{.Status}}' 2>/dev/null)"
  printf 'CA-Datei     %s\n' "$([[ -f ${CA_FILE} ]] && echo vorhanden || echo fehlt)"
  printf 'Systemtrust  %s\n' "$(ca_im_systemtrust && echo verankert || echo 'NICHT verankert (sudo trust anchor --store ...)')"
  printf 'Sysctl-Grenze %s (Ziel <= %d, Datei %s)\n' "$(sysctl -n ${SYSCTL_KEY} 2>/dev/null || echo ?)" "${SYSCTL_WANT}" "$([[ -f ${SYSCTL_FILE} ]] && echo da || echo fehlt)"
  podman logs --tail 5 llm-proxy 2>/dev/null | cut -c1-160 || true
}

case "${1:---apply}" in
  --apply)   apply_all ;;
  --render)  render_files ;;
  --check)   check_all ;;
  --ca-import) ca_import ;;
  --status)  status_all ;;
  *) die "Unbekannter Modus: $1 (erlaubt: --check, --render, --ca-import, --status, kein Argument)" ;;
esac
