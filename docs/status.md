# Projektstatus

Stand: 2026-11-16, geprueft am selben Tag; Beweis-Befehle am 2026-11-17 erneut
bestaetigt (LAN-Abschnitt, Dashboard-Zaehlbild, Einheiten-Messgroesse). Fruehere Stiche (WSL-Zeit,
Pennyroyal-Kaltstarts, Tuning-Runden) stehen im `CHANGELOG.md` und im
Git-Verlauf: `git show HEAD:docs/status.md`. Fortsetzungsanker ist
`docs/HANDOFF.md`.

## Verifizierter Zustand (2026-11-16)

### CDI-Beschreibung

Der Arztlauf meldet die CDI-Beschreibung als „38 h alt“. Das ist kein Fehler, sondern
ein Hinweis mit Verfallsdatum: die Datei `etc/containers/cdi.d/nvidia.com.yaml` entsteht
bei `make podman`, und dieses Ziel startet einen GPU-Testcontainer. Die Grafikkarte
gehoert aber dem Modell (Grundregel 2), deshalb wird sie nicht nebenbei fuer eine
Auffrischung angefasst.

Nachholen, wenn eines davon zutrifft: NVIDIA-Treiber gewechselt, neue CUDA-Version,
neue Karte, oder die Laufzeit klagt ueber fehlende Geraete. Dann in einem fenster
ohne laufende Anfragen:

```bash
make podman            # erzeugt CDI neu und testet die Karte in einem Wegwerfcontainer
./scripts/doctor.sh    # die Warnung muss weg sein
```

### Alarmierung

Der Alertmanager laeuft **bewusst ohne Empfaenger** (Betreiberentscheidung vom
2026-11-16). Alarme erscheinen unter `http://127.0.0.1:9093` und in Prometheus;
ntfy und E-Mail sind in `config/monitoring/alertmanager.yml` vorbereitet und
auskommentiert. Das ist ein dokumentierter Soll-Zustand, damit niemand die fehlende
Zustellung als Defekt bucht. Einzelheiten und Umschaltweg: `docs/monitoring.md#alarmkanal`.

### Pennyroyal-Abweichung

`quadlet/pennyroyal.container` ist die eine Datei im Repo, deren committete Fassung
**bewusst** vom Generatorergebnis abweicht. Committet ist der Betreiber-Fork
`localhost/flash-next-sm120:serving` (Beschreibung: „FORK sm120, all speed switches,
mamba 19 lazy"); `scripts/50-install-pennyroyal.sh` wuerde das Upstream-Bild
`ghcr.io/jpezzulli/sglang-rtxpro6000:v2.5.3` schreiben, weil es den Fork nicht kennt.

Entscheidung des Betreibers vom 2026-11-16: der **Fork bleibt die committete Wahrheit**,
und `make drift` / `make ci` werden nicht durch Wegsehen gruen, sondern durch eine
dokumentierte Ausnahmeliste in `scripts/check-drift.sh` (`ausnahmen=(...)`). Die
Abweichung wird bei jedem Lauf mit Kurzstatistik, Begruendung und Aufloeseweg
ausgegeben; eine neue Ausnahme entsteht ausschliesslich dort, mit Datum und
Begruendung.

Aufloesen laesst sich die Ausnahme auf zwei Arten: die Fork-Werte (Bild,
ulimits `memlock`/`nofile`, Modellpfad) in den Generator schreiben, dann ist die
Ausnahme leer; oder `git checkout HEAD -- quadlet/pennyroyal.container` zurueck auf
Upstream, falls der Fork nicht mehr gebraucht wird. Bis dahin gilt: auf diesem Rechner
laeuft die Laufzeit ohnehin als `flash-next-v3` (Abschnitt Inferenz-Laufzeit), die
Pennyroyal-Unit ist die vorbereitete, nicht die benutzte Fassung.

### Sicherung

`./scripts/backup.sh` hat ihr erstes Archiv erzeugt
(`state/backups/llm-infra-backup-<Zeitstempel>.tar.gz`, ausserhalb von Git): Konfiguration
aus dem Repo, `pg_dump` der Gateway-Datenbank, Zustandsordner von Chat, Grafana und
Portal, dazu ein `manifest.json` mit Pruefsummen. Anssehen: `./scripts/restore.sh --list`.
Das Skript meldet Teilfehler jetzt als Fehler (Rueckgabewert 1 mit naechstem Befehl);
zuvor fehlten still die nicht lesbaren Grafana-Ausfuhrordner `png/csv/pdf`, waehrend
der Lauf mit 0 endete. Diese drei Ordner sind ausgeschlossen, weil sie dem Nutzer des
Grafana-Containers hoeren und bei Bedarf neu erzeugt werden - kein Zustand, der
verloren gehen kann.

### Chat-Dienst und Gateway-Zugang

Der Chat haelt einen **eigenen** Gateway-Schluessel (Alias `open-webui`, ausgegeben
von `scripts/71-gateway-keys.sh`, gespeichert in
`~/.config/llm-infra/gateway-proxy/issued-keys.txt`). Der Master-Schluessel des
Gateways steht nicht mehr in `open-webui.env` - er kann Schluessel anlegen und
loeschen und gehoert nicht in eine Anwendung fuer Anwenderinnen und Anwender.
Ausgestellt wird er von `chat_service_key()` in `lib/secrets.sh`, damit dafuer keine
zweite Stelle im Repo existiert. Gemessen: Anmeldung und Anfrage ueber die
Oberflaeche, `POST /api/chat/completions` mit HTTP 200, angezeigte Modellantwort
(„Paris“), keine Konsolenfehler; `scripts/doctor.sh` Pruefpunkt 16 meldet drei OK und
schlaegt fehl, wenn der Master doch wieder im Chat steht (gegentestet).

Gateway-Eigenmetriken (`litellm_*`) fehlen in Prometheus **bewusst**: das
Chainguard-Image enthaelt kein `prometheus-client`, `/metrics` liefert 404. Die
Lebensdauer laeuft ueber `llm_unit_active{unit="litellm"}` aus
`scripts/collect-host-facts.sh`; gemessen (2026-11-17) melden 19 von 20 Serien den
Wert 1 - die zwanzigste ist `pennyroyal` und meldet bewusst 0 (Referenz-Unit, laeuft
hier nicht). Freischaltweg
fuer echte Gateway-Metriken: `docs/monitoring.md`.

### Inferenz-Laufzeit

Der unmanaged Container `flash-next-v3` (vLLM, Bild
`localhost/qwen38-fp4-tp1:v3`) laeuft und bindet sein API nur auf
`127.0.0.1:30000`. Pennyroyal gibt es auf diesem Rechner nicht; die
Identitaet der Laufzeit steht in `config/host.env`. Metriken stellt der
Weiterleiter aus diesem Repo bereit: User-Unit `llm-vllm-forwarder.service`
auf Port 30001, gebunden an Loopback und die Adresse der bevorzugten
Standard-Route (rootless pasta reicht die Host-Loopback nicht an Container
durch - Begruendung in `docs/runtime.md`). Die auswaertige
`luni-vllm-pub.service` ist retired.

```bash
podman ps --filter name=flash-next-v3 --format '{{.Names}}\t{{.Status}}\t{{.Ports}}'
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:30000/health          # 200
./scripts/73-setup-vllm-forwarder.sh --check                                     # OK: Runtime-Weiterleiter laeuft
ss -tln | grep 30001                                                             # LISTEN 127.0.0.1, 192.168.0.198
```

### Gateway und Datenbank

`litellm` (Bild `docker.litellm.ai/berriai/litellm:v1.105.0`, nur
`127.0.0.1:4000`, startet nach `litellm-postgres`) antwortet keylos auf die
Liveliness. Der Modellkatalog in `config/litellm.yaml` fuehrt 13 Modelle:
Profile `direct-*`, `standard-*`, `local-*`, dazu `qwen3.8-flash-next`,
`bonsai-2-27b` und zwei Siemens-Modelle. `gpt-6-luna` ist ausgelassen, weil
`~/.config/llm-infra/chatgpt-tokens/auth.json` nur den Geraeteanfrage-
Zeitstempel traegt, kein Token (Einordnung in `docs/operations.md`).

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:4000/health/liveliness   # 200
grep -c 'model_name:' config/litellm.yaml                                           # 13
python3 -c "import json;d=json.load(open('$HOME/.config/llm-infra/chatgpt-tokens/auth.json'));print(sorted(d))"
```

### Chat (Open WebUI)

`open-webui.service` (Bild `ghcr.io/open-webui/open-webui:v0.11.4`) hoert auf
`127.0.0.1:3001`; Port 3000 ist Grafana, nicht die Chat-Oberflaeche. `/health`
liefert true, `/api/version` 0.11.4, und `/api/models` antwortet ohne Sitzung
mit 401 - die Liste nennt die Gateway-Modelle und gehoert nicht an
Nichtangemeldete.

Pruefung am 2026-11-16 mit Playwright (Chromium headless, 1680x1000, Screens
unter `/tmp/qa/screens/openwebui-*.png`): Einstieg `/` leitet auf `/auth`,
Anmeldung gelingt, Hauptseite ohne Konsolenfehler, Modellauswahl geoeffnet mit
14 Eintraegen (13 Gateway-Modelle zuzueglich das eigene `arena-model`), und
eine echte Frage an `qwen3.8-flash-next` wird textlich beantwortet (erwartetes
Wort in der Antwort, 1-2 s). Gateway-seitig belegt: `POST /v1/chat/completions
HTTP/1.1" 200 OK` im Journal von `litellm.service` zur Sekunde der Anfrage, aus
dem Netz des Chat-Dienstes.

Behoben sind vier Daengel, alle im Generator: der Ollama-Anbieter stand an und
hing an `host.docker.internal:11434` (hier hoert nichts), es gab kein
Standardmodell, die Registrierung war offen bei null Konten (der erste
Browser-Besuch waere Administrator geworden), und der Update-Hinweis legte beim
ersten Oeffnen ein modales Fenster ueber die Seite, das jeden Klick blockierte.

```bash
./scripts/60-install-open-webui.sh --check          # zehn Pruefpunkte, alle ok
./scripts/64-setup-open-webui-account.sh --check    # Konto und Anmeldung
journalctl --user -u litellm.service --since '-5 minutes' --no-pager | grep -c 'chat/completions'
```

Zwei Punkte bleiben beim Hersteller und sind hier nur dokumentiert: das Bild
enthalt keine Uebersetzung (kein `i18n/`-Verzeichnis unter `/app`,
`/i18n/en.json` antwortet mit dem Single-Page-Geruest), deshalb stehen in den
Administratoren-Verstellungen rohe Schluessel wie
`settings.admin.connections.title`; und `/admin/settings` ist keine eigene
Seite, sondern oeffnet die Verstellungen als Modal - die URL faellt auf `/`
zurueck, die Inhalte sind erreichbar und die Verbindungsseite zeigt
`http://litellm:4000/v1`.

### Oeffentlicher Zugang (443 am Azure-Gateway)

Tunnel-Unit aktiv und aktiviert; die vier oeffentlichen Routen liefern die
erwarteten Codes, per DNS-Name und uber die Roh-IP identisch (Einzelheiten:
`docs/gateway-proxy.md`). Basic-Auth-Personen: 5
(`owner, thomas, martin, johannes, holger`). Die retired Unit liegt als
`~/.config/systemd/user/reverse-tunnel.service.retired-20261116`.

```bash
systemctl --user is-active llm-reverse-tunnel.service               # active
systemctl --user is-enabled llm-reverse-tunnel.service              # enabled
cut -d' ' -f1 ~/.config/llm-infra/gateway-proxy/team-users.txt      # 5 Namen
for p in /health/liveliness /v1/models / /grafana/; do
  printf '%-22s %s\n' "$p" "$(curl -sk -o /dev/null -w '%{http_code}' \
    --resolve edipoc-gateway.westeurope.cloudapp.azure.com:443:20.73.54.102 \
    https://edipoc-gateway.westeurope.cloudapp.azure.com$p)"
done                                                                        # 200 401 401 401
```

### Beobachtungsstapel

Prometheus, Grafana, Loki, Alloy, Alertmanager, Dozzle, node- und
GPU-Exporter laufen. Alertmanager `/-/ready` liefert 200 und haelt drei
aktive Alarme bereit (2x `PCIeAnbindungReduziert`, `SwapAktiv`) - der Weg
Prometheus -> Alertmanager ist damit belegt, ein Versandkanal ist bewusst
noch nicht gewaehlt. Alloy sammelt die Quadlet-Container ueber die
Docker-API und `flash-next-v3` ueber das Journal.

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:9093/-/ready       # 200
curl -s http://127.0.0.1:9093/api/v2/alerts | python3 -c 'import json,sys;print(len(json.load(sys.stdin)),"aktive Alarme")'
curl -s 'http://127.0.0.1:9090/api/v1/targets' | python3 -c '
import json,sys
for t in json.load(sys.stdin)["data"]["activeTargets"]:
    print("%-14s %s" % (t["labels"]["job"], t["health"]))'
```

Erwartetes Bild: alle acht Jobs up - `alertmanager, alloy, gpu, grafana,
loki, node, prometheus, vllm`. Der Job `grafana` braucht `metrics_path:
/grafana/metrics`, weil Grafana im Unterpfad laeuft (`docs/monitoring.md`).

### Dashboards

Fuenf provisionierte Dashboards, zusammen 120 Panel-Abfragen (Nachzaehlung
2026-11-17; nach dem Umbau in `5fa6ab0` waren es kurz 121, eine Abfrage fiel seither
weg). Die
Browser-Pruefung am 2026-11-16 (Playwright, Chromium headless, 1680x1000,
eingeloggt als admin): 89 Panelfelder, davon 8 ohne Daten - ausschliesslich
ZFS/ARC-Panels aus `04-speicher.json` (dieser Rechner hat kein ZFS), alle
anderen gefuellen. Kein `sglang`-
Verweis mehr in Regeln und Dashboards, Loki-Panels haengen an der
provisionierten Loki-Datenquelle.

```bash
grep -o '"expr"' config/monitoring/grafana/provisioning/dashboards/0*.json | wc -l   # 120
grep -c sglang config/monitoring/grafana/provisioning/dashboards/0*.json             # alles 0
podman exec systemd-prometheus promtool check rules /etc/prometheus/conf/alerts.yml   # SUCCESS: 24 rules
./scripts/validate.sh                                                            # rc=0
```

Ehemaliger Befund, inzwischen behoben: die drei Panels ohne Anfrage in
`05-agent-observatorium.json` ("Auslastung je Geraet", "VRAM-Bedarf je Geraet",
"VRAM-Fuellstand") fragen seit `5fa6ab0` lebende `nvidia_smi:*`-Reihen;
`./scripts/validate.sh` meldet aktuell keine Panels ohne Anfrage mehr.

### Wiki und Timer

`~/work/hermes-wiki` ist geklont, der `site/`-Build entsteht durch
`scripts/wiki-rebuild.sh` (venv mit mkdocs-material). Der Rebuild-Timer laeuft
alle 30 Minuten und hat nichts zu tun, wenn kein neuer Commit anliegt
(`site/.built-sha` gleicht HEAD). Der Kennzahlentimer laeuft wie vorgesehen;
Runtime-, Gateway-, Crashguard- und GitOps-Timer sind auf diesem Rechner
bewusst (noch) nicht installiert.

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3003/    # 200
git -C ~/work/hermes-wiki rev-parse HEAD | head -c 12; echo; cat ~/work/hermes-wiki/site/.built-sha
systemctl --user list-timers --no-pager | head -5
```

## LAN-Zugang ueber HTTPS - gemessener Stand 2026-11-17

Aufgabe aus `.omo-work/todo-local-llm-network.md` (LAN-HTTPS fuer den
Windows-Arbeitsplatz), umgesetzt in `scripts/74-setup-local-proxy.sh`,
`config/proxy/Caddyfile.template` und `quadlet/llm-proxy.container`.

**Wie der Zustand erreicht wurde:** Der Proxy-Container haengt jetzt in
`llm-observability` **und** `llm-inference` (litellm loest nur dort auf) und
veroeffentlicht 443 auf `127.0.0.1` plus der LAN-Adresse aus
`LAN_BIND_IPS` in `config/host.env`. Die LAN-Sites kommen als ganzer Block aus
dem Generator und fehlen vollstaendig, wenn `LAN_BIND_IPS` leer ist - ohne LAN
steht also kein einziges Zeichen Zugang ins Netz im Caddyfile.

**Gemessen 2026-11-17 (Host 192.168.0.198, Name `cachyos-x8664`, mit `--cacert`
gegen die exportierte Caddy-CA, `--check` endet mit rc=0):**

| Adresse | Ergebnis |
|---|---|
| https://homepage.cachyos-x8664/ | 200 (Portal, Titel "LUNI Mission Control") |
| https://homepage.cachyos-x8664/anleitung/ | 200 (statische Anleitung) |
| https://grafana.cachyos-x8664/grafana/ | 200 ohne Anmeldung (anonyme Lese-Rolle) |
| https://littlem.cachyos-x8664/v1/models | 401 ohne Schluessel; mit Schluessel echte Antwort `qwen3.8-flash-next` ueber `/v1/chat/completions` (HTTP 200, Modelltext erhalten) |
| https://llm-direct.cachyos-x8664/v1/models | 401 (Alias von `littlem`, gleiches Verhalten) |
| https://dozzle.cachyos-x8664/ | 401 ohne / 200 mit Basic-Auth (`logs`) |
| https://direct-llm.cachyos-x8664/v1/models | 401 ohne / 401 mit falschem / 200 mit richtigem Zugang (`inference`); Antwort nennt Modell `flash-next` |
| beliebiger anderer Name | TLS-Abbruch bzw. 403 - die Fallback-Site reicht an kein Backend weiter |
| https://homepage.localhost/ , https://grafana.localhost/grafana/ | unveraendert 200 (Loopback-Fallback bleibt) |

**Kein Backend-Port im Netz:** `--check` prueft die Ports 3000, 3001, 3002,
3100, 4000, 5432, 8080, 9090, 9093, 9835, 30000, 3003, 9100, 12345 und 8120 auf
Loopback-Ausschliesslichkeit; alle 15 sind Loopback-only (gemessen mit
`ss -tlnH`; 12345 und 8120 horchen nur in den Containernetzen, erscheinen auf dem
Host also gar nicht). Absichtlich ausgenommen ist 30001, der Weiterleiter: er
 muss die geroutete Adresse des Hosts bedienen, damit Container im Inferenz-Netz
die Runtime erreichen (`docs/runtime.md`).

**Zugangsdaten:** Basic-Auth nur fuer Dozzle und die direkte vLLM-Route (beide
ohne eigene Anmeldung stromaufwaerts). Hashes in
`~/.config/llm-infra/proxy/lan-auth.env`, lesbare Werte in
`~/.config/llm-infra/proxy/lan-credentials.txt`, beide 0600 und ausserhalb von
Git; das Caddyfile enthaelt nur `{env.*}`-Platzhalter. Erzeugt mit
`caddy hash-password` aus dem gepinnten Bild. Ein zweiter Lauf laesst vorhandene
Hashes in Ruhe (`ensure_auth_file` ist idempotent).

**Warum nicht 80/443 auf allen Adaptern:** veroeffentlicht wird nur, was in
`LAN_BIND_IPS` steht. Der Kerneltrenner `net.ipv4.ip_unprivileged_port_start=443`
(`/etc/sysctl.d/99-llm-infra-local-proxy.conf`) bleibt, weil rootless Podman
sonst gar kein 443 binden kann; er oeffnet nichts von allein.

**Namensaufloesung und Wurzel-Download (gemessen 2026-11-17):** die dnsmasq-Zone
aus `scripts/75-setup-local-dns.sh` beantwortet alle sechs Namen auf
`192.168.0.198`; `dig +short @192.168.0.198 homepage.cachyos-x8664 A` liefert die
Adresse, `dig +short @192.168.0.198 example.com A` bleibt leer (kein offener
Resolver), `ss -lun` kennt nur `192.168.0.198:53` (die Zone wird mit `dig @192.168.0.198` direkt
gefragt, also ohne jeden Umweg ueber den Host-Resolver). Auf diesem Rechner
zuschaetzlich vorhanden: eine /etc/hosts-Zeile mit denselben sechs Namen - der
Arztlauf vergleicht beider Adressen und meldet Abweichung, weil zwei Quellen fuer
dieselbe Tatsache der klassische stale-IP-Fehler nach einem DHCP-Wechsel sind.
Der Root-Download
`http://192.168.0.198:8081/caddy-local-authority-root.crt` liefert 200 und ist
bytegleich mit der exportierten Wurzel; andere Pfade geben 404. Bewusst 8081 und
nicht 80: die Kerneltrenner laesst rootless kein 80, und 8080 ist
Loopback-only. Bewusst keine mDNS-Zone: `.local` wuerde jeden Zertifikatsnamen
und `HOMEPAGE_ALLOWED_HOSTS` aendern.

**Rueckweg:** `LAN_BIND_IPS=` in `config/host.env` leer setzen und
`./scripts/74-setup-local-proxy.sh` laufen lassen - damit ist der Stand von
2026-11-16 (nur Loopback) wieder erreicht, ohne Veraenderungen an Unit, Caddy-CA
oder Tunnel.

**Windows-Seite:** noch nicht am Geraet geprueft (kein Zugriff auf den
Windows-PC aus dieser Sitzung). Die Befehle dafuer sind dokumentiert:
`--print-hosts` (hosts-Datei) und `--ca-export` (Root-Import, Fingerprint-Vergleich)
in `docs/operations.md`, Abschnitt "Windows 11". Abnahme dort nachtragen, sobald
der PC erreicht werden kann.

## Lokaler HTTPS-Zugang ueber Namen - gemessener Stand 2026-11-16

* Neuer verwalteter Proxy: Container `llm-proxy` (Caddy, Netz `llm-observability`,
  nur `127.0.0.1:443`). Generator `scripts/74-setup-local-proxy.sh`
  (`make local-proxy`), Vorlage `config/proxy/Caddyfile.template`, Pruefung
  `--check`, Caddy-CA im Systemtrust (`--ca-import`). Details und Fehlerbilder:
  `docs/operations.md` (Abschnitt "Lokaler HTTPS-Zugang ueber Namen").
* `https://homepage.localhost/` liefert 200 mit curl ohne `-k`; Host-Freigabe
  ueber `HOMEPAGE_ALLOWED_HOSTS` in `config/host.env` (Generator
  `scripts/60-install-homepage.sh`).
* `https://grafana.localhost/grafana/` liefert 200 ohne Anmeldung, ohne `301`
  auf die Gateway-Adresse und ohne Azure-Links in der Auslieferung. Werte in
  `~/.config/llm-infra/grafana.env`: anonyme Lese-Rolle, keine Anmeldemaske,
  Einbettung an, `GF_SERVER_ROOT_URL=https://grafana.localhost/grafana/`
  (Vorlage `config/grafana.env.example`).
* Panel-Einbettung anonym messbar: alle fuenf Dashboards (runtime, gpu, host,
  storage, agent-observatorium) liefern `d-solo?panelId=2` = 200 ohne Cookies,
  kein `X-Frame-Options: deny` im Kopf. Dafuer musste die
  `Environment=GF_AUTH_ANONYMOUS_ENABLED=false`-Zeile aus
  `quadlet/grafana.container` weichen: podman laesst `--env` gegen `--env-file`
  gewinnen, die Datei wurde sonst stillschweigend unterdrueckt.
* Oeffentliche Routen unveraendert (nach dem Umbau gemessen): `/grafana/` 401,
  `/v1/models` 401, `/` 401, `/health/liveliness` 200. Anonym reicht nicht
  nach aussen - Basic-Auth auf dem Gateway sitzt vor Grafana.

## Portal (gethomepage) auf 2.6.0 - gemessener Stand 2026-11-16

* `homepage.service` laeuft auf dem gepinnten Bild
  `ghcr.io/gethomepage/homepage@sha256:3e38fe788223cb46a3ce1f046ef11667b40f7707fdca0dcbfa3f86c5c42bf1e8`
  (Tag v2.6.0, Quelle `versions.lock`). Der Sprung von v2.4.0 war noetig,
  weil erst 2.6.0 Tabs kennt und `/app/public` beim Start indexiert.
* Tabs aus `config/homepage/settings.yaml` (Dashboard, LLM, INFRA, SYSTEM,
  BETRIEB, TOOLS) erscheinen im gerenderten HTML und sind per Playwright
  klickbar; Screens `/tmp/qa/screens/portal-260-*.png`.
* Symbole: versioniert unter `config/homepage/icons/`, dateiweise ro-Bind
  nach `/app/public/icons/`; alle 16 Dateien liefern 200 (gemessen per
  curl und im Browser `naturalWidth > 0`, keine kaputten Bilder, keine
  Rohschluessel). Playwright-Netzliste ueber das ganze Portal: nur
  `homepage.localhost` und `grafana.localhost` (beide ::1), 0 Anfragen an
  `cdn.jsdelivr.net` oder andere externe Hosts.
* Der Installer rollt die Unit jetzt selbst ueber `lib/units.sh` aus
  (`install_units` + `systemd_reload`, Start/Restart nur bei Abweichung
  von Unit-Datei oder laufendem Bild). Vorher installierte
  `scripts/60-install-homepage.sh` die Unit nie dorthin, wo Quadlet sie
  liest, und der Live-Stand hing auf v2.4.0 fest.

```bash
podman ps --filter name=llm-homepage --format '{{.Image}}'   # Digest-Bild v2.6.0
./scripts/60-install-homepage.sh --check                       # rc 0, alles OK
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3002/icons/grafana.svg  # 200
curl -s -o /dev/null -w '%{http_code}\n' https://homepage.localhost/               # 200
```

## Anleitung unter `/anleitung/` - gemessener Stand 2026-11-16

Die Kachel **Agent-Anleitung** im TOOLS-Tab fuehrte ins Leere: sie zeigt auf
`https://homepage.localhost/anleitung/`, bedient wurde die Seite von niemandem
(`308`/`404`). Auslieferung jetzt ueber den lokalen Proxy:

- Datei `config/proxy/site/anleitung/index.html`, vom Container `llm-proxy` unter
  `/srv/llm-proxy/site` gelesen (Bind in `scripts/74-setup-local-proxy.sh`) und von
  Caddy in einer eigenen `handle`-Blende vor das Portal geschaltet
  (`config/proxy/Caddyfile.template`). Beide Blenden schliessen einander aus, die
  Seite wird also nicht zusaetzlich ans Portal weitergereicht.
- Inhalt: der Nutzer-Teil ist aus dem alten Bestand zurueckgeholt
  (`luni-llmops-linux`, Zweig `fix/homepage-local-recovery`,
  `stacks/router/gateway/config/site/anleitung.html` - dort war es die
  Windows-Einrichtungsseite mit drei Schritten), darunter der Betriebsteil mit
  Zugangswegen, erstem Befehl, gemessenem Gesundheitsstand und den offenen Punkten.
- Das Windows-ZIP wird **nicht** aus diesem Repo ausgeliefert: es enthaelt
  Zertifikate, die bleiben ausserhalb von Git. Die Kachel verlinkt den Bestandsordner.
- Gemessen: `https://homepage.localhost/anleitung/` = `200`, `/anleitung` = `308` auf
  die Seite mit Schraegstrich, Titel `LUNI | Anleitung`, Ueberschrift `Lokale KI.
  Einmal einrichten.`; Kachelklick im TOOLS-Tab oeffnet sie als `_blank` mit `200`
  (Schirm `/tmp/qa/screens/anleitung.png`). Anfragen gehen ausschliesslich an
  `homepage.localhost`/`grafana.localhost`, keine externen Mittel (stylesheet und
  Schriften lokal).

**Zielkonflikt, der bewusst bleibt:** `GF_SERVER_ROOT_URL=https://grafana.localhost/grafana/`
macht Grafana hinter dem benannten Namen und einbettbar. absolute Links in Grafana
(icons, return-URLs) zeigen dadurch auf `grafana.localhost` und sind fuer die
oeffentliche Azure-Flaeche nicht erreichbar - dort hilft der Weg ueber
`http://127.0.0.1:3000/grafana/` nicht mehr, weil derselbe Container beide Flaechen
bedient. Aufgewogen gegen den Wunsch des Betreibers nach benannten HTTPS-Namen und
Grafana ohne Anmeldung; die oeffentliche Flaeche bleibt bei `/v1/*` (Schluessel noetig).

## Bekannte Abweichungen (bewusst, dokumentiert)

- Der Weiterleiter bindet Port 30001 an die Adresse der bevorzugten
  Standard-Route, also ins Kabel-LAN; die WLAN-Adresse ist seit 2026-11-17 zu.
  Begruendung, Messung und der Weg zur sauberen Loesung (Weiterleiter als
  Container): `docs/runtime.md`, Aufgabe `docs/HANDOFF.md` Nr. 19.
- `make drift` ist auf diesem Rechner nicht gruen, und zwar grundlegend: die
  committete `quadlet/pennyroyal.container` ist seit laengerem Handarbeit, nicht
  Generator-Ausgabe. Der Generator schreibt eine andere Unit (Bild
  `ghcr.io/jpezzulli/sglang-rtxpro6000:v2.5.3` mit Digest, anderes
  `Description`, ohne die beiden `Ulimit`-Zeilen, Modellpfad `/srv/llm-models`
  statt `/home/z000g9hu/models`), committet ist die Fassung des Referenzrechners
  (`localhost/flash-next-sm120:serving`, memlock/nofile-Deckel, eigene
  Start-Gate-Zeile). Keines der beiden Bilder laeuft hier - die Laufzeit ist der
  unmanaged Container `flash-next-v3`. Welche Fassung die Referenz ist, muss der
  Betreiber entscheiden; danach Generator oder committete Datei angleichen. Nichts
  davon ungeprueft anwenden: `apply-runtime-unit.sh` wuerde das Referenzbild tauschen.
- `gpt-6-luna` ist ohne echtes Geraet-Token aus dem Katalog gestrichen;
  Reaktivierung in `docs/operations.md`.
- 8 Panels in `04-speicher.json` (ZFS, ARC und PLE) zeigen "keine Daten", weil dieser
  Rechner nichts davon hat; auf dem ZFS-Referenzrechner fuellen sie sich.
- Die Chat-Oberflaeche zeigt in den Administratoren-Verstellungen rohe
  Uebersetzungsschluessel. Grund liegt im Bild, nicht in dieser Konfiguration:
  `/app` fuehrt kein `i18n/`-Verzeichnis, und `/i18n/en.json` beantwortet die
  App mit dem Single-Page-Geruest statt mit JSON. Beheben koennte nur ein
  anderes Bild (Stand: `v0.11.4`, siehe `versions.lock`).
- `scripts/doctor.sh` und `scripts/healthcheck.sh` kennen noch keinen
  Chat-Fall; die Pruefung liefert bis dahin
  `./scripts/60-install-open-webui.sh --check`.
- Browser-Pruefung am 2026-11-16 mit Playwright (Chromium headless, 1680x1000):
  89 Panelfelder in fuenf Dashboards, 8 ohne Daten (ZFS/ARC), sonst keine
  "No data"-Felder; Dozzle zeigt alle sieben erwarteten Container; das Portal
  meldet keine fehlerhaften Widgets. Screenshots: `/tmp/qa/screens/`.
- Die Arbeiten des Tages 2026-11-16 sind in mehreren Themen-Commits gesichert
  (`git log --oneline -8`, `./scripts/session-checkpoint.sh --status`);
  offene Punkte stehen in `docs/HANDOFF.md`.

## Betriebsregeln

- Keine ZFS-Pools erstellen, zerstoeren oder umstrukturieren.
- Dauerhafte Aenderungen nur ueber dieses Repository.
- Geheimnisse bleiben ausserhalb von Git.
- Die Grafikkarte bleibt exklusiv beim Modell (ADR 0013).

## Naechste Befehle

```bash
cd /srv/work/llm-infra-setup
./scripts/doctor.sh                        # gefuehrte Diagnose, nennt den naechsten Befehl
./scripts/70-setup-gateway-proxy.sh --check  # oeffentlicher Zugang in Ordnung?
./scripts/74-setup-local-proxy.sh --check    # lokaler HTTPS-Zugang ueber Namen in Ordnung?
./scripts/60-install-monitoring.sh --check   # Beobachtungsstufe vollstaendig?
./scripts/60-install-open-webui.sh --check   # Chat-Oberflaeche und Gateway-Weg?
./scripts/session-checkpoint.sh --status     # was ist noch ungesichert?
```
