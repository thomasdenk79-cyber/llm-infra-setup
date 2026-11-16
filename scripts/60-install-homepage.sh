#!/usr/bin/env bash
# Portal (gethomepage) einrichten: Konfiguration an den Live-Ordner uebergeben
# und die Quadlet-Unit erzeugen.
#
#   ./scripts/60-install-homepage.sh            Dateien schreiben, Unit
#                                               installieren, Portal bei
#                                               Bedarf neu starten (Standard)
#   ./scripts/60-install-homepage.sh --check    pruefen, nichts aendern
#
# Die Unit wird wie bei allen anderen Diensten ueber lib/units.sh
# (install_units/systemd_reload/start_units) nach
# ~/.config/containers/systemd ausgerollt - dieser Pfad ist die einzige
# Stelle, die Quadlets installiert; von Hand dorthin kopieren ist falsch.
#
# Einzelne Quelle der Wahrheit fuer die erlaubten Hosts ist config/host.env
# (Variable HOMEPAGE_ALLOWED_HOSTS, Default: Loopback auf Port 3002 plus der
# Name des lokalen HTTPS-Proxys). Der oeffentliche Zugang der Kollegen haengt
# hinter Caddy auf dem Gateway-Rechner; dessen Homepage-Block setzt den
# Host-Header auf die Upstream-Adresse ("header_up Host {upstream_hostport}" in
# config/gateway/Caddyfile.template), deshalb prueft Homepage den Loopback-Wert
# 127.0.0.1:3002 und keinen Gateway-Namen. Der lokale Zugang ueber Namen
# (https://homepage.localhost/, scripts/74-setup-local-proxy.sh) liefert den
# Namen selbst als Host-Header, deshalb gehoert homepage.localhost in die Liste.
# Werte fuer 8443 oder LAN-Adressen gehoeren nicht mehr hierher: der
# LAN-HTTPS-Proxy ist durch den Gateway-Tunnel ersetzt.
#
# Die Unit-Datei quadlet/homepage.container wird hier geschrieben und traegt
# den Header "GENERIERT von". Aendern am Generator, nicht an der Datei -
# ./scripts/check-drift.sh (make drift) prueft genau das.
#
# Bildpin (2026-11-16): Version und Digest stehen in versions.lock
# (homepage, homepage_image, homepage_image_digest). Die Unit referenziert den
# Digest, damit ein spaeteres Nachziehen nicht unbemerkt eine andere Fassung
# bringt. Noetig wurde der Sprung von v2.4.0 auf v2.6.0, weil erst 2.6.0 Tabs
# kennt (layout.<gruppe>.tab im ausgelieferten Build belegt: activeTab /
# setActiveTab im Chunk pages/index-*.js). 2.6.0 kennt die Service-Widgets
# mjpeg, iframe, prometheusmetric, prometheus und customapi; ein rss-Block
# fehlt weiterhin und renderte nur "Missing rss".
#
# Symbole (2026-11-16): die Garnitur liegt unter config/homepage/icons/ im Repo
# und wird dateiweise nach /app/public/icons/<datei> eingebunden (read-only).
# Warum einzeln: ein Verzeichnis-Bind auf /app/public schattiert die
# mitgelieferten Locales ab, und das Portal zeigt Rohschluessel statt Text
# (COMMON.MS, common.number). Nackte Iconnamen in services.yaml waeren
# aufrufe an cdn.jsdelivr.net - auf diesem Rechner unerwuenscht - also
# verweisen die Kacheln auf /icons/<datei>. v2.6.0 indexiert /app/public beim
# Start; neue oder geaenderte Symboldateien brauchen daher einen Portal-Neustart.
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${root}/lib/common.sh"
source "${root}/lib/units.sh"
# shellcheck disable=SC1091  # Rechnerdatei, absichtlich ausserhalb von Git
[[ -f "${root}/config/host.env" ]] && source "${root}/config/host.env"

homepage_port=3002   # muss zu PublishPort in der Unit-Datei passen
homepage_allowed_hosts="$(printf '%s' "${HOMEPAGE_ALLOWED_HOSTS:-}" | tr -d '[:space:]')"
if [[ -z "${homepage_allowed_hosts}" ]]; then
  homepage_allowed_hosts="127.0.0.1:${homepage_port},localhost:${homepage_port},homepage.localhost"
fi
# Zeichenerlaubnis statt Regex: die bash-ERE scheitert an den eckigen Klammern
# der IPv6-Notation, und der Wert landet ohne Umwege in einer Unit-Datei.
# Whitespace wird vorher entfernt, weil Homepage selbst nur auf Komma trennt -
# ein ' host' in der Liste wuerde sonst stillschweigend nie passen.
homepage_allowed_hosts_clean="$(printf '%s' "${homepage_allowed_hosts}" | tr -cd -- '-A-Za-z0-9.,:*_[]')"
[[ "${homepage_allowed_hosts_clean}" == "${homepage_allowed_hosts}" ]] || \
  die "HOMEPAGE_ALLOWED_HOSTS enthaelt ungueltige Zeichen: '${homepage_allowed_hosts}'. Erlaubt sind host:port-Paare durch Komma getrennt, oder '*' fuer keine Pruefung."

# Bildreferenz: Digest aus versions.lock, Tag nur als Kommentar in der Unit.
homepage_image_tag="$(sed -n 's/^homepage:[[:space:]]*//p' "${root}/versions.lock" | head -1)"
homepage_image_repo="$(sed -n 's/^homepage_image:[[:space:]]*//p' "${root}/versions.lock" | head -1)"
homepage_image_digest="$(sed -n 's/^homepage_image_digest:[[:space:]]*//p' "${root}/versions.lock" | head -1)"
[[ -n "${homepage_image_repo}" && -n "${homepage_image_digest}" ]] || \
  die "versions.lock nennt kein homepage_image / homepage_image_digest - nachtragen: homepage_image: ghcr.io/gethomepage/homepage:v2.6.0 und homepage_image_digest: sha256:..."
[[ "${homepage_image_repo}" == *"@sha256:"* ]] && \
  die "homepage_image in versions.lock traegt bereits einen Digest - erwartet wird Bild:tag, der Digest steht in homepage_image_digest."
homepage_image="${homepage_image_repo%:*}@${homepage_image_digest}"
[[ "${homepage_image_repo}" == "ghcr.io/gethomepage/homepage:"* ]] || \
  die "erwartetes Bild ist ghcr.io/gethomepage/homepage, gefunden: ${homepage_image_repo}"

config_dir="${XDG_CONFIG_HOME:-${HOME}/.config}/llm-infra/homepage"
icons_dir="${root}/config/homepage/icons"
[[ -d "${icons_dir}" ]] || die "Symbolordner fehlt: ${icons_dir} - Kacheln wuerden ins Leere zeigen."

# Symbolbindungen: eine Zeile pro Datei, stabil sortiert (make drift vergleicht
# bytegenau). Pfad als @CONFIG_ROOT@ - dasselbe Muster wie die anderen Quadlets,
# lib/units.sh setzt es beim Ausrollen in die einsatzfaehige Unit ein.
icon_binds=''
while IFS= read -r datei; do
  icon_binds+="Volume=@CONFIG_ROOT@/config/homepage/icons/${datei}:/app/public/icons/${datei}:ro"$'\n'
done < <(find "${icons_dir}" -mindepth 1 -maxdepth 1 -type f -printf '%f\n' | LC_ALL=C sort)
icon_binds="${icon_binds%$'\n'}"
[[ -n "${icon_binds}" ]] || die "Keine Symbole unter ${icons_dir} - mindestens eine Datei wird bentigt."

generate_quadlet() {
  # Unit-Text auf der Standardausgabe; render_quadlet schreibt ihn ins Repo,
  # der --check vergleicht darueber, ohne Dateien anzufassen.
  local text
  text="$(cat <<'UNIT'
# GENERIERT von scripts/60-install-homepage.sh - dort ändern, nicht hier.
[Unit]
Description=LLM Infrastructure Homepage portal
After=llm-observability-network.service
Wants=llm-observability-network.service

[Container]
# Bild ueber Digest gepinnt (Tag __HOMEPAGE_IMAGE_TAG__, Digest
# __HOMEPAGE_IMAGE_DIGEST__, Quelle versions.lock).
Image=__HOMEPAGE_IMAGE__
ContainerName=llm-homepage
Network=llm-observability.network
PublishPort=127.0.0.1:3002:3000
# Erlaubte Host-Header: kommen aus config/host.env (HOMEPAGE_ALLOWED_HOSTS).
# Jeder andere Host antwoordet mit 400 - Pruefung in src/middleware.js der
# gepinnten Version.
Environment=HOMEPAGE_ALLOWED_HOSTS=__HOMEPAGE_ALLOWED_HOSTS__
Volume=%h/.config/llm-infra/homepage:/app/config:Z,U
# Symbole einzeln in den public-Ordner des Containers (read-only). Kacheln
# verweisen auf /icons/<datei>. Ein Bind auf /app/public als Ganzes waere
# falsch: er schattiert die mitgelieferten Locales ab (Rohschluessel im Text).
__ICON_BINDS__

[Service]
Restart=on-failure
RestartSec=15

[Install]
WantedBy=default.target
UNIT
)"
  text="${text//__HOMEPAGE_IMAGE_TAG__/${homepage_image_tag}}"
  text="${text//__HOMEPAGE_IMAGE_DIGEST__/${homepage_image_digest}}"
  text="${text//__HOMEPAGE_IMAGE__/${homepage_image}}"
  text="${text//__HOMEPAGE_ALLOWED_HOSTS__/${homepage_allowed_hosts}}"
  text="${text//__ICON_BINDS__/${icon_binds}}"
  printf '%s\n' "${text}"
}

render_quadlet() {
  generate_quadlet > "${root}/quadlet/homepage.container"
}

write_config() {
  install -d -m 0755 "${config_dir}"
  # Der Container liest /app/config aus diesem Ordner: die versionierten YAMLs
  # sind die einzige Quelle, Handaenderungen am Live-Ordner sind ueberschrieben.
  cp -f "${root}"/config/homepage/*.yaml "${config_dir}/"
}

pinned_image_id() {
  # Bild-ID des in versions.lock gepinnten Manifests, leer wenn nicht im
  # Bildspeicher. Podman zuerst komplett in eine Variable lesen: ein frueh
  # abbrechendes awk im laufenden Pipe beendete mit pipefail still den
  # Skriptablauf (SIGPIPE, rc 141).
  local bilder zeile
  bilder="$(podman images --no-trunc --format '{{.ID}} {{.Digest}}' 2>/dev/null || true)"
  zeile="$(printf '%s\n' "${bilder}" | awk -v d="${homepage_image_digest}" '$2 == d {print $1}')"
  zeile="${zeile%%$'\n'*}"
  printf '%s' "${zeile#sha256:}"
}

check_all() {
  local rc=0
  # 1) Kommt die committete Unit exakt aus diesem Generator? Verglichen, nicht
  # nachgeschrieben: der --check darf keine Datei im Repo veraendern.
  if ! generate_quadlet | cmp -s - "${root}/quadlet/homepage.container" 2>/dev/null; then
    printf 'FEHLT: quadlet/homepage.container weicht vom Generator ab - 60-install-homepage.sh ausfuehren\n'; rc=1
  fi
  # 2) Liegen die versionierten YAMLs unveraendert im Live-Ordner?
  for yaml in "${root}"/config/homepage/*.yaml; do
    local ziel="${config_dir}/$(basename -- "${yaml}")"
    if [[ ! -f "${ziel}" ]]; then
      printf 'FEHLT: %s fehlt im Live-Ordner %s - 60-install-homepage.sh ausfuehren\n' "$(basename -- "${yaml}")" "${config_dir}"; rc=1
    elif ! cmp -s "${yaml}" "${ziel}"; then
      printf 'FEHLT: %s weicht vom Live-Ordner ab - 60-install-homepage.sh ausfuehren\n' "$(basename -- "${yaml}")"; rc=1
    fi
  done
  # 3) Liegt die installierte Unit identisch in ~/.config/containers/systemd?
  # Genau hier lag der Fehler: die Repo-Fassung war auf 2.6.0, die ausgelegte
  # Unit blieb auf v2.4.0, weil der Installer sie nie ausgerollt hat.
  if ! installed_unit_diff homepage.container >/dev/null 2>&1; then
    printf 'FEHLT: installierte Unit in %s weicht von quadlet/homepage.container ab - 60-install-homepage.sh ausfuehren\n' "${UNIT_DIR}"
    printf '       naechster Schritt: systemctl --user daemon-reload && systemctl --user restart homepage.service\n'; rc=1
  fi
  # 4) Sind alle Symbole im Live-Container erreichbar (200 auf /icons/...)?
  local code
  for datei in $(find "${icons_dir}" -mindepth 1 -maxdepth 1 -type f -printf '%f\n' | LC_ALL=C sort); do
    code="$(curl -s -o /dev/null -m 10 -w '%{http_code}' "http://127.0.0.1:${homepage_port}/icons/${datei}" || echo 000)"
    [[ "${code}" == "200" ]] || { printf 'FEHLT: /icons/%s liefert %s statt 200 - Portal neu starten (v2.6.0 indexiert /app/public beim Start): systemctl --user restart homepage.service\n' "${datei}" "${code}"; rc=1; }
  done
  # 5) Laeuft der Container mit dem gepinnten Digest?
  if have podman; then
    local liste laufend erwartet
    liste="$(podman ps --format '{{.Names}}' 2>/dev/null || true)"
    if [[ $'\n'${liste}$'\n' == *$'\n'llm-homepage$'\n'* ]]; then
      laufend="$(podman inspect llm-homepage --format '{{.Image}}' 2>/dev/null || echo unbkannt)"
      # Der Bildspeicher fuehrt den Manifest-Digest; darueber laesst sich der
      # gepinnte Wert eindeutig auf eine Bild-ID abbilden (pinned_image_id).
      erwartet="$(pinned_image_id)"
      if [[ -z "${erwartet}" ]]; then
        printf 'HINWEIS: gepinntes Bild %s ist nicht im Bildspeicher - podman pull %s\n' "${homepage_image_tag}" "${homepage_image}"
      elif [[ "${laufend#sha256:}" != "${erwartet}" ]]; then
        printf 'FEHLT: laufender Container nutzt ein anderes Bild als versions.lock (%s statt %s)\n' "${laufend}" "${erwartet}"
        printf '       naechster Schritt: ./scripts/60-install-homepage.sh (startet bei Abweichung selbst neu)\n'; rc=1
      else
        printf 'OK: Portal laeuft mit dem gepinnten Bild (%s, %s)\n' "${homepage_image_tag}" "${homepage_image_digest}"
      fi
    else
      printf 'HINWEIS: llm-homepage laeuft nicht - naechster Schritt: systemctl --user start homepage.service\n'
    fi
  fi
  # 6) Portal antwortet?
  code="$(curl -s -o /dev/null -m 10 -w '%{http_code}' "http://127.0.0.1:${homepage_port}/" || echo 000)"
  [[ "${code}" == "200" ]] || { printf 'FEHLT: Portal auf 127.0.0.1:%s liefert %s statt 200\n' "${homepage_port}" "${code}"; rc=1; }
  [[ "${rc}" == 0 ]] && printf 'OK: Portal ist auf dem Stand der Generatoren (%s, Symbole lokal)\n' "${homepage_image_tag}"
  return "${rc}"
}

case "${1:---render}" in
  --render)
    install -d -m 0755 "${root}/quadlet"
    render_quadlet
    write_config
    # Unit ausrollen wie alle anderen Dienste: lib/units.sh ist die einzige
    # Stelle, die Quadlets nach ~/.config/containers/systemd bringt
    # (render_unit + Symlink nach default.target.wants).
    # Vor dem Ausrollen merken, ob der Live-Zustand hinter der Repo-Fassung
    # herhaengt: install_units ueberschreibt die installierte Unit, danach ist
    # der Unterschied nicht mehr messbar. Neustart ist noetig, wenn die
    # Unit-Datei oder das laufende Bild abweicht (Quadlet startet mit
    # podman run --replace; Bild- und Bind-Aenderungen wirken erst im neuen
    # Container). Wiederholte Aufrufe ohne Aenderung starten nichts neu.
    vorher_abweicht=0
    bild_abweicht=0
    if unit_is_active homepage.container; then
      installed_unit_diff homepage.container >/dev/null 2>&1 || vorher_abweicht=1
      if have podman; then
        erwartet="$(pinned_image_id)"
        if [[ -n "${erwartet}" ]]; then
          laufend="$(podman inspect llm-homepage --format '{{.Image}}' 2>/dev/null || echo unbkannt)"
          [[ "${laufend#sha256:}" == "${erwartet}" ]] || bild_abweicht=1
        fi
      fi
    fi
    install_units homepage.container
    systemd_reload
    if ! unit_is_active homepage.container; then
      log 'Portal-Einheit ist nicht aktiv - wird gestartet.'
      start_units homepage.container
    elif [[ "${vorher_abweicht}${bild_abweicht}" != 00 ]]; then
      [[ "${vorher_abweicht}" == 1 ]] && log 'Installierte Unit unterschied sich von der Repo-Fassung.'
      [[ "${bild_abweicht}" == 1 ]] && log 'Laufender Container nutzte nicht das gepinnte Bild.'
      log 'Portal wird neu gestartet.'
      systemctl --user restart homepage.service
    else
      log 'Unit und laufendes Bild entsprechen der Repo-Fassung - kein Neustart erforderlich.'
    fi
    log "Homepage-Unit installiert: http://127.0.0.1:${homepage_port}/, erlaubte Hosts: ${homepage_allowed_hosts}"
    log "Bild: ${homepage_image_tag} (${homepage_image_digest})"
    log 'Konfiguration kopiert nach '"${config_dir}"' (versionierte YAMLs sind die einzige Quelle).'
    log 'Naechster Schritt: ./scripts/60-install-homepage.sh --check'
    ;;
  --check)
    check_all
    ;;
  *) die "Unbekannter Modus: $1 (erlaubt: --check, kein Argument)" ;;
esac
