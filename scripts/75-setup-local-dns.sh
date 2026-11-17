#!/usr/bin/env bash
# Namensaufloesung fuer die LAN-Namen des LLM-Stapels (dnsmasq, eine Zone).
#
#   ./scripts/75-setup-local-dns.sh            ausrollen (sudo, idempotent)
#   ./scripts/75-setup-local-dns.sh --plan     zeigen, was geschrieben wuerde
#   ./scripts/75-setup-local-dns.sh --render   Zonendatei auf stdout
#   ./scripts/75-setup-local-dns.sh --check    nur pruefen
#   ./scripts/75-setup-local-dns.sh --remove   Zone und Drop-in entfernen, Dienst stoppen
#
# Warum ueberhaupt: die LAN-Namen (homepage.<LAN_DOMAIN> und die fuenf anderen)
# gibt es in keinem DNS. Ohne diese Zone pflegt jedes Geraet eine hosts-Datei -
# die haeufigste Ursache fuer "komme nicht an den Portal".
#
# Antwortend wird ausschliesslich die Zone des Rechners: keine Weiterleitung,
# damit kein offener Resolver (Gegentest in --check: fremde Anfrage muss leer
# bleiben). Der Dienst horcht nur auf den konfigurierten LAN-Adressen, die
# Host-Aufloesung ueber systemd-resolved (127.0.0.53) bleibt unangetastet.
#
# Zwei Dateien, beide nur hier erzeugt:
#   /etc/llm-infra/dnsmasq/lan-zone.conf              die Zone selbst
#   /etc/systemd/system/dnsmasq.service.d/99-llm-infra.conf
# Das Paket liefert kein /etc/dnsmasq.d und seine conf-dir-Zeile ist
# auskommentiert, deshalb haengt das Drop-in dem Dienst ausschliesslich unsere
# Zonendatei an (--conf-file) und laedt /etc/dnsmasq.conf des Pakets nicht.
# --enable-dbus bleibt drin: die Einheit ist Type=dbus, ohne dbus-name wird sie
# nie aktiv.
#
# Bewusst kein mDNS/.local: das wuerde jeden Zertifikatsnamen, die
# Portal-Freigabe und die Doku aendern. Diese Zone laesst alle Namen, wie sie sind.
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${root}/lib/common.sh"

if [[ -f "${root}/config/host.env" ]]; then
  source "${root}/config/host.env" \
    || die "config/host.env liesst sich nicht einlesen (siehe Zeile oben). Mehrere Adressen in Anfuehrungszeichen setzen: LAN_BIND_IPS=\"192.168.0.198\""
fi

ZONE_DATEI='/etc/llm-infra/dnsmasq/lan-zone.conf'
DROPIN_DIR='/etc/systemd/system/dnsmasq.service.d'
DROPIN="${DROPIN_DIR}/99-llm-infra.conf"
DIENST='dnsmasq.service'
LAN_DOMAIN="${LAN_DOMAIN:-$(hostname)}"
LAN_IPS=(${LAN_BIND_IPS:-})
# Zusaetzliche Endungen, unter denen die Zone ebenfalls antwortet. Windows
# haengt an zweiteilige Namen Suchendungen an (die vom Router verteilte
# Domain), und ein Name wie homepage.<LAN_DOMAIN>.lan geht dann an den
# Router statt an uns. Leer laesst die Zone exakt so, wie sie ist.
LAN_DNS_SUFFIXES=(${LAN_DNS_SUFFIXES:-})
ROLLEN=(homepage grafana littlem llm-direct dozzle direct-llm)

ist_ipv4() {
  # Vier Oktette, jedes 0..255 - ein Zahlenspiel wie 192.168.0.999 ergaebe eine
  # Zone, die niemand je anfragt.
  local ip="${1:-}" teile o
  [[ -n "${ip}" ]] || return 1
  IFS='.' read -ra teile <<< "${ip}"
  (( ${#teile[@]} == 4 )) || return 1
  for o in "${teile[@]}"; do
    [[ "${o}" =~ ^[0-9]{1,3}$ ]] || return 1
    (( 10#${o} <= 255 )) || return 1
  done
  return 0
}

vorbedingungen() {
  (( ${#LAN_IPS[@]} > 0 )) || die 'LAN_BIND_IPS ist leer (config/host.env) - ohne LAN-Adresse bringt die Zone nichts. Zuerst: ./scripts/74-setup-local-proxy.sh'
  local ip
  for ip in "${LAN_IPS[@]}"; do
    ist_ipv4 "${ip}" || die "LAN_BIND_IPS enthaelt keine gueltige IPv4: '${ip}' (erwartet vier Oktette 0..255)"
  done
  [[ -n "${LAN_DOMAIN}" ]] || die 'LAN_DOMAIN ist leer und der Rechnername ist nicht zu ermitteln.'
  need_cmd dnsmasq 'Jetzt ausführen: sudo pacman -S dnsmasq   (oder: make install)'
}

render_zone() {
  local ip
  cat <<ZONE
# GENERIERT von scripts/75-setup-local-dns.sh - dort aendern, nicht hier.
# Beantwortet ausschliesslich *.${LAN_DOMAIN}; keine Weiterleitung, kein offener
# Resolver, kein Lauschen ausserhalb der konfigurierten LAN-Adressen.
strict-order
bind-interfaces
port=53
no-resolv
no-hosts
domain-needed
cache-size=100
ZONE
  for ip in "${LAN_IPS[@]}"; do printf 'listen-address=%s\n' "${ip}"; done
  printf 'local=/%s/\n' "${LAN_DOMAIN}"
  for ip in "${LAN_IPS[@]}"; do printf 'address=/%s/%s\n' "${LAN_DOMAIN}" "${ip}"; done
  local ende
  for ende in "${LAN_DNS_SUFFIXES[@]}"; do
    for ip in "${LAN_IPS[@]}"; do printf 'address=/%s.%s/%s\n' "${LAN_DOMAIN}" "${ende}" "${ip}"; done
  done
}

render_dropin() {
  # ExecStart= einmal leer = zuruecksetzen, dann der eigentliche Start. Ohne
  # --enable-dbus bleibt Type=dbus ewig bei "activating".
  cat <<DROP
# GENERIERT von scripts/75-setup-local-dns.sh - dort aendern, nicht hier.
# Haengt dem Paket-Dienst ausschliesslich unsere Zonendatei an.
[Service]
ExecStartPre=
ExecStartPre=/usr/bin/dnsmasq --test --conf-file=${ZONE_DATEI}
ExecStart=
ExecStart=/usr/bin/dnsmasq -k --enable-dbus --user=dnsmasq --pid-file --conf-file=${ZONE_DATEI}
DROP
}

systemo() {  # systemctl als root - ohne sudo -n lehnt systemd den Daemon-Reload ab
  sudo -n systemctl "$@" || die "sudo ohne Passwort moeglich? Sonst von Hand: sudo systemctl $*"
}

zone_pruefen() {
  # dnsmasq prueft selbst, bevor etwas liegt: eine kaputte Zeile wuerde sonst
  # den Dienst treffen, der auch anderen Geraeten die Namen liefert.
  local tmp
  tmp="$(mktemp)"
  render_zone > "${tmp}"
  dnsmasq --test --conf-file="${tmp}" >/dev/null 2>&1 \
    || { rm -f "${tmp}"; die "Zonen-Datei ungueltig - ansehen: ./scripts/75-setup-local-dns.sh --render"; }
  rm -f "${tmp}"
}

schreiben() {  # schreiben <pfad> <inhalt>
  local pfad="$1" inhalt="$2" dir
  if [[ -f "${pfad}" ]] && [[ "$(cat "${pfad}")" == "${inhalt}" ]]; then
    log "unveraendert: ${pfad}"
    return 0
  fi
  dir="$(dirname "${pfad}")"
  sudo -n mkdir -p "${dir}" || die "sudo ohne Passwort moeglich? Sonst: sudo mkdir -p ${dir}"
  printf '%s\n' "${inhalt}" | sudo -n tee "${pfad}" >/dev/null \
    || die "sudo ohne Passwort moeglich? Sonst: ./scripts/75-setup-local-dns.sh --render | sudo tee ${pfad}"
  log "geschrieben: ${pfad}"
}

apply_all() {
  vorbedingungen
  zone_pruefen
  if [[ "${LLM_DRIFT:-0}" == '1' ]]; then
    log 'Prueflauf (LLM_DRIFT=1): nichts geschrieben, kein systemctl, kein sudo.'
    return 0
  fi
  schreiben "${ZONE_DATEI}" "$(render_zone)"
  schreiben "${DROPIN}" "$(render_dropin)"
  systemo daemon-reload
  systemo enable --now "${DIENST}" >/dev/null 2>&1 || true
  systemo restart "${DIENST}"
  log "Namensaufloesung ausgerollt: *.${LAN_DOMAIN} -> ${LAN_IPS[0]} (Dienst ${DIENST})"
  log 'Next: 192.168.0.198 im Router als DNS eintragen - dann braucht kein Geraet eine hosts-Datei.'
  log 'Pruefen:       ./scripts/75-setup-local-dns.sh --check'
  log 'Zuruecknehmen: ./scripts/75-setup-local-dns.sh --remove'
}

remove_all() {
  if [[ "${LLM_DRIFT:-0}" == '1' ]]; then log 'Prueflauf (LLM_DRIFT=1): es wird nichts entfernt.'; return 0; fi
  local pfad
  for pfad in "${DROPIN}" "${ZONE_DATEI}"; do
    if [[ -f "${pfad}" ]]; then
      sudo -n rm -f "${pfad}" || die "sudo ohne Passwort moeglich? Sonst: sudo rm -f ${pfad}"
      log "entfernt: ${pfad}"
    else
      log "war nicht vorhanden: ${pfad}"
    fi
  done
  [[ -d "${DROPIN_DIR}" ]] && sudo -n rmdir "${DROPIN_DIR}" 2>/dev/null || true
  systemo daemon-reload
  systemo stop "${DIENST}" 2>/dev/null || true
  systemo disable "${DIENST}" 2>/dev/null || true
  log 'Dienst gestoppt. Pruefen: ./scripts/doctor.sh   (Routen selbst prueft 74-setup-local-proxy.sh --check)'
}

check_all() {
  vorbedingungen
  local rc=0 ip rolle antwort fremd start
  systemctl is-active --quiet "${DIENST}" \
    || { printf 'FEHLT: %s laeuft nicht - starten: ./scripts/75-setup-local-dns.sh\n' "${DIENST}"; return 1; }
  [[ -f "${ZONE_DATEI}" ]] \
    || { printf 'FEHLT: %s fehlt - ausrollen: ./scripts/75-setup-local-dns.sh\n' "${ZONE_DATEI}"; rc=1; }
  [[ -f "${DROPIN}" ]] \
    || { printf 'FEHLT: %s fehlt - ohne Drop-in liest der Dienst die Paketkonfiguration statt der Zone\n' "${DROPIN}"; rc=1; }
  start="$(systemctl show -p ExecStart --value "${DIENST}" 2>/dev/null)"
  [[ "${start}" == *"--conf-file=${ZONE_DATEI}"* ]] \
    || { printf 'FEHLT: %s startet nicht mit unserer Zonendatei (ExecStart: %s)\n' "${DIENST}" "${start:-unbekannt}"; rc=1; }
  if ! have dig; then
    printf 'OK: %s laeuft mit unserer Zone (dig fehlt, Antworten ungeprueft; sudo pacman -S bind)\n' "${DIENST}"
    return "${rc}"
  fi
  for ip in "${LAN_IPS[@]}"; do
    for rolle in "${ROLLEN[@]}"; do
      antwort="$(dig +short "@${ip}" "${rolle}.${LAN_DOMAIN}" A 2>/dev/null | head -1)"
      [[ "${antwort}" == "${ip}" ]] \
        || { printf 'FEHLT: %s.%s liefert an %s nicht %s (Antwort: %s)\n' "${rolle}" "${LAN_DOMAIN}" "${ip}" "${ip}" "${antwort:-leer}"; rc=1; }
    done
  done
  local ende
  for ende in "${LAN_DNS_SUFFIXES[@]}"; do
    [[ -n "${ende}" ]] || continue
    antwort="$(dig +short "@${LAN_IPS[0]}" "homepage.${LAN_DOMAIN}.${ende}" A 2>/dev/null | head -1)"
    [[ "${antwort}" == "${LAN_IPS[0]}" ]] \
      || { printf 'FEHLT: homepage.%s.%s liefert %s statt %s (Suchendung vom Router?)\n' \
             "${LAN_DOMAIN}" "${ende}" "${antwort:-leer}" "${LAN_IPS[0]}"; rc=1; }
  done
  fremd="$(dig +short "@${LAN_IPS[0]}" example.com A 2>/dev/null | head -1)"
  [[ -z "${fremd}" ]] \
    || { printf 'FEHLT: %s beantwortet fremde Namen (%s) - kein offener Resolver!\n' "${DIENST}" "${fremd}"; rc=1; }
  if (( ${rc} == 0 )); then
    printf 'OK: Namensaufloesung - %d Namen unter %s auf %s, fremde Anfragen abgewiesen\n' \
      "${#ROLLEN[@]}" "${LAN_DOMAIN}" "${LAN_IPS[0]}"
  fi
  return "${rc}"
}

modus="${1:-}"
case "${modus}" in
  '')         apply_all ;;
  --plan)     vorbedingungen; log 'Geschrieben wuerde:'; render_zone; printf -- '--- Drop-in ---\n'; render_dropin ;;
  --render)   vorbedingungen; render_zone ;;
  --check)    check_all ;;
  --remove)   remove_all ;;
  *) die "Unbekannter Modus: ${modus} (erlaubt: --plan, --render, --check, --remove, kein Argument)" ;;
esac
