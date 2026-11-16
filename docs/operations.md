# Betrieb

Kurzfassung fuer jede Woche, Ausfuehrliche fuer den ersten Tag.

## taeglich

```bash
./scripts/doctor.sh --short    # 10 Sekunden, sagt was zu tun ist
```

Nichts zu tun, wenn da `Alles in Ordnung.` steht.

## Dieser Rechner: Laufzeit und Gateway (Stand 2026-11-16)

Es laeuft NICHT Pennyroyal. Die Inferenz-Laufzeit ist der unmanaged Container
`flash-next-v3` (vLLM, Bild `localhost/qwen38-fp4-tp1:v3`), gestartet mit
`podman run` und veroeffentlicht nur auf `127.0.0.1:30000`. Die kanonische
Ansprache kommt aus `config/host.env` (`RUNTIME_CONTAINER=flash-next-v3`,
`RUNTIME_UNIT=` leer, `RUNTIME_PORT=30000`), Pruefskripte und
Kennzahlensammler ziehen daraus Containername, Port und Logweg
(`runtime_identity` in `lib/units.sh`). Wer
`systemctl --user status pennyroyal.service` fragt, bekommt korrekt
`inactive` mit `not-found`: Die Unit existiert auf diesem Rechner nicht.

```bash
podman ps --filter name=flash-next-v3 --format '{{.Names}}\t{{.Status}}\t{{.Ports}}'
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:30000/health   # 200
```

Damit Container im Inferenz-Netz (Prometheus, LiteLLM) die Runtime erreichen,
stellt ein Weiterleiter API und Metriken auf Port 30001 bereit. Laeuft als
Repo-Unit: `scripts/73-setup-vllm-forwarder.sh` mit
`scripts/vllm-pub-forwarder.py` und `systemd/llm-vllm-forwarder.service`.
Gebunden wird an Loopback plus die Host-Adressen - rootless pasta reicht die
Host-Loopback nicht an Container durch, Details und Verengungsoptionen in
`docs/runtime.md`. Die fruehere auswaertige Unit ist retired
(`~/.config/systemd/user/luni-vllm-pub.service.retired-20261116`); zwei
Instanzen streiten sonst um Port 30001:

```bash
./scripts/73-setup-vllm-forwarder.sh --check
systemctl --user status llm-vllm-forwarder.service
```

Der Gateway (`quadlet/litellm.container`, nur `127.0.0.1:4000`) haelt das
Modell `chatgpt/gpt-6-luna` zurueck: Der Generator `scripts/60-install-gateway.sh`
entfernt den Modelleintrag und seine Fallback-Zeilen aus
`config/litellm.yaml`, solange unter `~/.config/llm-infra/chatgpt-tokens` kein
echtes Token liegt (eine JSON-Datei mit `access_token`, `refresh_token`,
`tokens` oder `token_bundle`). Grund: ohne gespeicherte Token ruft der Proxy
beim Start den OpenAI-Geraetefluss (Device-Code) auf und der Endpunkt 4000
bindet nicht - der Gateway bliebe stumm, ohne dass ein Fehler dazu fuehrt.
Eine reine Merkdatei mit Geraeteanfrage-Zeitstempel (heute der Stand:
`auth.json` enthaelt nur `device_code_requested_at`) zaehlt nicht als
Anmeldung. Der Ausfall der Stufe ist ungefaehrlich: Die Faellkette
`qwen3.8-flash-next -> bonsai-2-27b` bleibt erhalten, nur der dritte Ausweg
entfaellt. Reaktivieren: den Geraetelogin einmalig durchfuehren (der
Device-Code erscheint im Gateway-Journal), danach den Generator erneut laufen
lassen - er nimmt Luna dann wieder auf:

```bash
./scripts/60-install-gateway.sh && systemctl --user restart litellm.service
curl -s http://127.0.0.1:4000/v1/models -H "Authorization: Bearer $(sed -n 's/^LITELLM_MASTER_KEY=//p' ~/.config/llm-infra/gateway.env)" | python3 -c 'import json,sys;print([m["id"] for m in json.load(sys.stdin)["data"]])'
```

(Wenn die Liste `gpt-6-luna` enthaelt, ist die Stufe wieder drin.)

## Start und Stopp

```bash
make deploy-non-gpu              # alles ausser Modell (Portal, Chat, Gateway, Beobachtung)
make deploy-ready                # kompletter Stack, wenn die GPU wieder da ist
./scripts/apply-runtime-unit.sh  # Repo-Aenderungen sicher aktivieren
./scripts/apply-runtime-unit.sh --restart-only   # Runtime neu starten (mit Rueckschutz)
```

Warum nicht einfach `systemctl --user restart pennyroyal`? Ein Kaltstart kostet
rund 15 Minuten und verwirft alle laufenden Anfragen. Das Skript bricht deshalb
ab, wenn Anfragen laufen, und merkt sich eine Sperre, wenn du
`PENNYROYAL_PROTECT=1` setzt (zum Beispiel vor einer Praesentation).

## Einzelne Teile

```bash
systemctl --user status pennyroyal.service --no-pager
journalctl --user -u pennyroyal.service -n 200 --no-pager
journalctl --user -u llm-infra-collect-facts.service --since "-10 min" --no-pager
systemctl --user list-timers --no-pager
podman ps --format '{{.Names}}\t{{.Status}}'
```

## Zugang und Adapter

| Zweck | Adresse | Hinweis |
|---|---|---|
| Portal | http://127.0.0.1:3002 | Einstieg fuer Menschen |
| Portal ueber Namen | https://homepage.localhost/ | lokaler Proxy, nur 127.0.0.1:443 (Abschnitt unten) |
| Grafana ohne Anmeldung | https://grafana.localhost/grafana/ | anonymes Lesen, Unterpfad /grafana/ (Abschnitt unten) |
| Chat (Open WebUI) | http://127.0.0.1:3001 | erster Account ist Admin |
| Gateway (OpenAI-kompatibel) | http://127.0.0.1:4000/v1 | Schluessel aus `credentials.txt` |
| Runtime direkt | http://127.0.0.1:30000/v1 | vLLM-Container `flash-next-v3`, nur fuer Diagnose und lokale Tools; bei Quadlet-Betrieb waere es Pennyroyal auf 8001 |
| Grafana | http://127.0.0.1:3000 | |
| Prometheus | http://127.0.0.1:9090 | Targetspruefung: `/targets` |
| Dozzle | http://127.0.0.1:8080 | |

Der eigene Rechner ist per SSH erreichbar und die Ports sind nur auf dem
Loopback gebunden. Von einem anderen Rechner im Netz kommst du so hin:

```bash
ssh -L 3000:127.0.0.1:3000 -L 3001:127.0.0.1:3001 deinrechner
```

## Lokaler HTTPS-Zugang ueber Namen

Ein verwalteter Caddy (Container `llm-proxy`, Quadlet
`quadlet/llm-proxy.container`) hoert im Netz `llm-observability` und ist nur
auf `127.0.0.1:443` veroeffentlicht. Er bedient zwei Sites:

| Adresse | Ziel | Gegencheck |
|---|---|---|
| https://homepage.localhost/ | Portal (`llm-homepage:3000`) | `curl -s -o /dev/null -w '%{http_code}' https://homepage.localhost/` -> 200 |
| https://grafana.localhost/grafana/ | Grafana (`grafana:3000`, Unterpfad bleibt) | `curl -s -o /dev/null -w '%{http_code}' https://grafana.localhost/grafana/` -> 200 ohne Login |

Warum Container-Namen statt 127.0.0.1: rootless pasta reicht die Host-Loopback
nicht an Container durch - der Proxy muss im Netz wohnen und gegen
`llm-homepage:3000`/`grafana:3000` proxen (gemessen mit `getent hosts` im Netz).

Befehle (alles idempotent, Vorlage `config/proxy/Caddyfile.template`):

```bash
make local-proxy                     # ausrollen: rendern, caddy validate, Unit starten
./scripts/74-setup-local-proxy.sh --check    # pruefen ohne zu aendern
./scripts/74-setup-local-proxy.sh --ca-import # Caddy-CA in den Systemtrust (sudo, nur dieser Rechner)
./scripts/74-setup-local-proxy.sh --status   # Unit, Listener, CA, Sysctl-Grenze
```

Nach dem ersten Ausrollen einmal `--ca-import` laufen lassen: erst dann gehen
`curl` ohne `-k` und der Browser ohne Warnung (Pruefung: `trust list
--filter=ca-anchors | grep Caddy`). Entfernen: `sudo trust anchor --remove
~/.local/share/llm-infra/caddy/ca/caddy-local-authority-root.crt`.

Das Veroeffentlichen von Port 443 als Benutzer erfordert die Kernelgrenze
`net.ipv4.ip_unprivileged_port_start <= 443`. Der Generator legt dafuer
idempotent `/etc/sysctl.d/99-llm-infra-local-proxy.conf` an (sudo). Bewusst 443
und nicht 80: Ports 80..442 bleiben privilegiert. Rueckbauaendern: Datei
loeschen und `sudo sysctl --system`.

Grafana ohne Anmeldung: `~/.config/llm-infra/grafana.env` (Generator
`scripts/60-install-monitoring.sh`, Vorlage `config/grafana.env.example`)
setzt anonyme Lese-Rolle, keine Anmeldemaske und Einbettung
(`GF_SECURITY_ALLOW_EMBEDDING=true`). Abnahme fuer Panel-Einbettungen:

```bash
curl -s -o /dev/null -b /dev/null -c /dev/null -w '%{http_code}\n' \
  'http://127.0.0.1:3000/grafana/d-solo/llm-infra-gpu?panelId=2'   # muss 200 liefern
curl -s -I -b /dev/null -c /dev/null 'http://127.0.0.1:3000/grafana/d-solo/llm-infra-gpu?panelId=2' | grep -i x-frame   # darf kein deny enthalten
```

Fehlerbilder:

- `400` vom Portal unter `homepage.localhost`: Host-Liste in
  `config/host.env` (`HOMEPAGE_ALLOWED_HOSTS`) ergaenzen, dann
  `make homepage && systemctl --user restart homepage.service`.
- `502` vom Proxy: Zielname loest im Netz nicht auf - `podman network
  inspect llm-observability` und `podman ps` pruefen; der Admin-Port 2019 ist
  absichtlich nur im Container-Loopback.
- `Permission denied` beim Starten von `llm-proxy.service`: Sysctl-Grenze
  zurueckgesetzt - `./scripts/74-setup-local-proxy.sh --apply` erneut laufen
  lassen.
- Zertifikatswarnung: `--ca-import` fehlt oder das Root hat gewechselt (Caddy
  erneuert die CA nach 8 Tagen Gueltigkeit) - `--ca-import` ist idempotent.
- Weisse Panel-Flaeche im Portal-iframe: `GF_SECURITY_ALLOW_EMBEDDING` fehlt
  (dann steht `X-Frame-Options: deny` im Kopf des d-solo-Aufrufs).

Der oeffentliche Zugang der Kollegen bleibt davon unberuehrt: Caddy auf dem
Gateway verlangt weiterhin Basic-Auth vor `/grafana/` und `/v1/models`
(401 ohne Zugangswerte, docs/gateway-proxy.md). Einziger Unterschied fuer
Auswaertige: die Wurzeladresse zeigt jetzt auf den lokalen Namen, daher
zeigen absolute Links der Grafana-Seite auf `grafana.localhost` - Details in
`docs/HANDOFF.md` (offene Punkte).

## Gateway-Fallback in drei Stufen

Hinweis 2026-11-16: Auf diesem Rechner ist die dritte Stufe derzeit
abgeschaltet (kein Geraet-Token, Generator streicht `gpt-6-luna`); die Kette
laeuft als zwei Stufen. Reaktivierung siehe Abschnitt "Dieser Rechner" oben.

Der Gateway (Modellalias `qwen3.8-flash-next`) failovert ueber eine dreistufige Kette: primaer
Pennyroyal auf der Blackwell; nach drei Retries im Abstand von 5 s Stufe zwei,
Bonsai 2 27B auf der RTX 3500 Ada (~45 tok/s); wenn lokal gar nichts geht,
Stufe drei Luna ueber ChatGPT-Plus-OAuth. Nach 60 s Cooldown versucht der
Router erneut den Primaer. Der lokale Gateway ist keyless und wird nur an
127.0.0.1 gebunden; die lokalen Upstreams erhalten interne Dummy-Werte, damit
das OpenAI-SDK keinen externen API-Schluessel verlangt. Luna braucht keinen
API-Schluessel - das
Geraet-Login legt seine Token unter `~/.config/llm-infra/chatgpt-tokens` ab,
das der LiteLLM-Container als `/etc/chatgpt-tokens` einhaengt. Geaendert wird
die Kette im Generator `scripts/60-install-gateway.sh`, nicht in der YAML.

### Effektive Kontextgrenzen und Routing-Nachweis

LiteLLM kennt fuer die Kette jetzt 524288 Eingabe-Token fuer Qwen, 250000 fuer
Bonsai und 272000 fuer Luna. Eine 1-Mio.-Token-Grenze ist nirgends eingestellt.
Die Antwort enthaelt im Feld `model` den tatsaechlich verwendeten Deploymentnamen
(`qwen3.8-flash-next`, `bonsai-2-27b` oder `gpt-6-luna`) - auch nach einem
Fallback. Der Failover-Drill gibt dieses Feld explizit als `modell=...` aus.

### Failover-Drill (wiederholbar, ohne laufende Anfragen)

```bash
./scripts/litellm-failover-drill.sh              # alle drei Stufen mit Zahlen
./scripts/litellm-failover-drill.sh --no-luna    # nur bis Bonsai
```

Der Drill faehrt eine Kopie der Router-Konfiguration als Wegwerf-Container
(`litellm-drill`, 127.0.0.1:4013) mit absichtlich totem Primaer (Port 4099) und
misst je Stufe Zeit und Token/s. Das lebende Gateway und die GPU-Runtime bleiben
unbertroffen. Letzter Lauf 2026-10-08 12:31: Kette nach totem Primaer in
22,2 s auf `bonsai-2-27b` gerettet (2 Token, Antwort OK), Bonsai direkt 0,27 s,
Luna direkt 1,73 s. Referenz der ersten bewiesenen Kette: 9,78 s Gesamt bei
~45 tok/s auf Bonsai (Langmessung).

### Uebernahme der Laufzeit bei Leerlauf

Solange die Laufzeit von Hand gestartet ist, gehoert ihr Container keiner Unit -
ein Rechnerneustart waere das Aus fuer das Modell. `scripts/takeover-when-idle.sh`
schliesst die Luecke, ohne die Neustart-Regel zu biegen: der Timer
`llm-runtime-takeover.timer` fragt alle 10 Minuten die Anfragezahl
(`vllm:num_requests_running` ueber den Weiterleiter, sonst die Runtime), und erst
nach drei aufeinanderfolgenden Nullmessungen meldet er Uebernahmebereitschaft in
`state/runtime-takeover/bereits.txt`.

Standardmaessig **startet er nichts neu** - die Regel des Repos ist ein eigener,
angekuendigter Neustartschritt, und eine Grafikkarte laeuft man nicht nebenbei
an. Ausfuehren ist dann ein Befehl:

```bash
./scripts/takeover-when-idle.sh --status              # Protokoll, Zaehler, Bereitstatus
./scripts/apply-runtime-unit.sh --takeover            # prueft die Anfragezahl erneut
```

Wer die Automatik will: `LLM_TAKEOVER_AUTOMATIK=1 ./scripts/takeover-when-idle.sh
--install`. Auch dann laeuft der Neustart durch `apply-runtime-unit.sh --takeover`,
das bei laufenden Anfragen und bei nicht lesbarer Anfragezahl abbricht - zwei
RIegel, einer vom Waechter, einer vom Werkzeug. Nach gelungener Uebernahme waehlt
sich der Timer selbst ab (`systemctl --user is-active llm-runtime-takeover.timer`).

### Waechter fuer den Gateway

```bash
./scripts/litellm-watchdog.sh --install     # systemd-Timer alle 5 Minuten
./scripts/litellm-watchdog.sh --reset       # Loopsperre nach 3 Neustarts loesen
```

Der Timer `llm-litellm-watchdog.timer` prueft die keyless Lebensanzeige
(`/health/liveliness`) plus einen 1-Token-Ruf durch den Router. Bei Ausfall:
laufende Anfragen der Runtime abfragen - zuerst der Weiterleiter auf
`${VLLM_METRICS_PORT:-30001}` (`vllm:num_requests_running`), dann die Runtime selbst
(`sglang:num_running_reqs` bleibt fuer Pennyroyal-Rechner stehen). **Ohne Zahl wird
verschoben, nicht neu gestartet**: eine nicht erreichbare Messgroesse ist kein
Freifahrtschein. Dann die GPU-Sperre
`${XDG_RUNTIME_DIR}/copilot-sm120-gpu.lock` per `flock -n` respektieren und erst
dann ausschliesslich `litellm.service` neu starten - nie die Runtime.
Nach drei ergebnislosen Neustarts greift die Loopsperre. Protokoll:
`state/litellm-watchdog/watchdog.log`. Das ist die Gateway-Ergaenzung zum
Runtime-Waechter `scripts/runtime-watchdog.sh`; als Ueberwachungsluecke waren beide
bislang ein M4-artiger Fall aus `docs/GRAFANA-DRIFT-AUDIT-2026-10-08.md`
(Soll-Ist-Widerspruch ohne aktiven Nachweis).

Der Runtime-Waechter laeuft auf diesem Rechner als `llm-runtime-watchdog.timer`
(alle 60 Sekunden) und **warnt nur**: `PENNY_WATCHDOG_RESTART` steht standardmaessig
auf 0, weil ein Runtime-Neustart ~15 Minuten kostet und laufende Anfragen wirft -
gegen die Regel, dass ein Neustart ein eigener, angekuendigter Schritt ist. An
laufenden Anfragen und an einer nicht lesbaren Anfragezahl verschiebt er sich
dasselbe Mal; welche Unit er meint, nimmt er aus `RUNTIME_UNIT` oder sucht die Unit
zum `ContainerName` aus `RUNTIME_CONTAINER` - geraten wird keine Unit, ohne Treffer
bleibt es bei der Warnung. Kontrollieren:

```bash
systemctl --user list-timers --all | grep watchdog   # beide muessen einen NEXT zeigen
journalctl --user -u llm-runtime-watchdog.service --no-pager -n 5
tail -5 state/litellm-watchdog/watchdog.log
```

### Luna-Token: Persistenz und Geraet-Login

Das ChatGPT-OAuth-Token liegt ausschliesslich unter
`~/.config/llm-infra/chatgpt-tokens/` (Datei `auth.json`) und wird vom
LiteLLM-Container als `/etc/chatgpt-tokens` eingehaengt. Frueher landete es im
fluechtigen `/root/.config/litellm/chatgpt` des Containers und war nach jedem
Neustart weg - das ist mit dem Volume behoben. Der ChatGPT-Geraet-Login
(Device-Code) laeuft beim ersten Start oder wenn das Token ablaeuft; der
Device-Code erscheint im Gateway-Journal. Laeuft der Refresh ohne neuen Code,
ist das Token gesund (pruefen: `./scripts/litellm-failover-drill.sh --no-luna`
weglassen und Stufe 3 ansehen). Erneuern: siehe
`docs/troubleshooting.md#luna-token-abgelaufen`.

### Monitoring gegen key-geschuetzte Endpunkte

`/health` und `/metrics` des Gateways verlangen den Master-Key als
`Authorization: Bearer ...`. Interne Pruefungen (healthcheck, Doctor,
Prometheus-Scrape) richten sich deshalb ausschliesslich gegen das keyless
`/health/liveliness`; andernfalls blaht jeder Scrape das Journal mit 401 plus
Traceback ("No api key passed in." / "Malformed API Key ... Bearer prefix").
Der vorbereitete, deaktivierte Scrape-Block in
`config/monitoring/prometheus.yml` dokumentiert beide Wege (keyless Liveness,
Bearer aus Secret-Datei - niemals Schluessel als Klartext im YAML).

## Modell austauschen

```bash
nano config/model.env                    # MODEL_ID und ggf. Bild anpassen
make model                               # laedt und setzt fort, wenn abgebrochen
make model-verify                         # prueft Indizes und Shard-Dateien
make ple-nvme                             # baut die SSD-Auslagerung neu
make pennyroyal && make apply-units       # Unit anpassen und sicher neu starten
make bench normal                         # Messung mit dem neuen Stand
```

Die Pruefung des Modellschreibens (Tokenizer, Vokabelkarte) passiert beim Start
in der Runtime selbst; sie ist Teil der `serve-flash-next-frspec.sh`.

## Treiber, Kernel, Neustart

```bash
make nvidia-driver         # danach Neustart noetig
sudo systemctl reboot
# nach dem Login:
cd /srv/work/llm-infra-setup
make podman                # CDI neu erzeugen (wichtig nach Hardwareaenderung!)
make deploy-ready
./scripts/doctor.sh
```

Die CDI-Datei `/etc/cdi/nvidia.yaml` enthaelt die PCI-Adresse der GPU. Nach
einem Tausch oder An-/Abstoeckern einer externen Karte muss sie neu erzeugt
werden - `make podman` erledigt das.

## Versionen aktualisieren

```bash
./scripts/00-preflight.sh            # Stand sichern
nano versions.lock                   # neue Version eintragen und begruenden
make pennyroyal                      # zieht und pumpt Digest nach
make validate && make drift          # Repo-Pruefung
make apply-units                     # erst dann laeuft die neue Version
```

Nie zwei Dinge gleichzeitig aendern (Modell und Bild, oder Treiber und Bild).

## Passwoerter erneuern

```bash
./scripts/rotate-secrets.sh             # ausser LiteLLM-Salt (begruendet im Skript)
./scripts/reset-grafana-password.sh     # nur Grafana
./scripts/show-credentials.sh           # aktuelle Werte anzeigen
```

Grafana speichert den Admin-Hash zusaetzlich in seiner Datenbank. Ein
erneuertes Podman-Secret allein setzt ein bereits initialisiertes Konto daher
nicht zurueck. Wenn nach dem Secret-Wechsel die Anmeldung weiterhin scheitert,
das neue Passwort aus der lokalen Zugangsdatei nehmen und im laufenden
Container angleichen:

```bash
systemctl --user restart grafana.service
podman exec systemd-grafana grafana cli admin reset-admin-password '<neues Passwort>'
```

Kein Passwort in Git oder in einer Shell-History ablegen. Ein temporaer
gesetztes Standardpasswort sofort durch ein eigenes Zufallspasswort ersetzen;
die Grafana-Portbindung auf `127.0.0.1` macht ein Standardpasswort nicht sicher.

## Mehrere Sitzungen gleichzeitig

Zwei Grenzen der Laufzeit (Anzeige mit `./scripts/doctor.sh`, Punkt 9):

* eine Anfrage: hoechstens 524288 Token
* alle Anfragen zusammen: 824384 Token Speicher (Kennzahl `max_total_num_tokens`)
* aufgenommene Anfragen gleichzeitig: Standard 4 (`PENNY_MAX_RUNNING_REQUESTS`)

Konsequenz fuer opencode-Sitzungen: eine Sitzung mit 300000 Token belegt mehr als ein Drittel. Ab etwa 200000-250000 Token verdichten (`compact`), oder dem Client
eine Grenze geben - dafuer ist das Skript da:

```bash
./scripts/configure-opencode-client.sh              # zeigen
./scripts/configure-opencode-client.sh --schreiben  # setzen (mit Sicherungskopie)
```

Es setzt `compaction` (auto, prune, reservierter Puffer) und
`models.<schluessel>.limit.context` - vorhandene Einstellungen bleiben erhalten.

## Beobachtung

Siehe `docs/monitoring.md`. Der kurze Weg:

```bash
make collector       # Host-Kennzahlen sofort sammeln und Timer aktivieren
make watchdog        # Waechter einschalten (warnt standardmaessig nur)
make bench normal 4  # 4 gleichzeitige Anfragen
```

### Logs mit `llmlogs`

`llmlogs` liest die Journald-Eintraege der LLM-/Agent-Units. Die Podman-
Container verwenden den Journald-Logtreiber, daher erscheinen Containerlogs
bereits dort; zusaetzliche `podman logs`-Streams wuerden sie doppelt und ohne
Journald-Formatierung ausgeben. Nur bestimmte Dienste:

```bash
llmlogs                              # letzte Stunde, dann weiter folgen
llmlogs pennyroyal litellm open-webui
llmlogs llm-node-exporter            # nur den Host-Exporter ansehen
llmlogs --no-follow --since 30m --lines 300
NO_COLOR=1 llmlogs                   # ANSI-Farben abschalten
llmlogs fork                         # SGLang-Test-Fork (Container flash-next-sm120, sonst neuestes candidate.log)
llmlogs --fork-last --lines 300      # neuestes ~/forge/fork/artifacts/sm120/*/candidate.log
llmlogs guard reference-start        # ~/forge/logs/guard.log und reference-start.log
```

Im interaktiven Terminal nutzt `llmlogs` dieselbe native, nach Journal-
Prioritaet formatierte Ausgabe wie `journalctl` direkt. Zum Beispiel liefert
`llmlogs --no-follow --lines 24 pennyroyal` denselben kompakten Stil wie
`journalctl --user -u pennyroyal.service -n 24 --no-pager`. `NO_COLOR=1`,
`TERM=dumb` oder Ausgabe ohne TTY deaktiviert Farben. Der Befehl zeigt
standardmaessig nur die ausgewaehlten LLM-/Agent-Units; einen Exporter gezielt
pruefen mit `llmlogs llm-node-exporter`. `Ctrl-C` beendet den Live-Follow.

Ein Exporterfehler in der Ausgabe stammt vom Dienst, nicht von `llmlogs`.
Insbesondere koennen doppelte Dateisystemmetriken fuer `/run/user` die
node_exporter-Scrapes beeintraechtigen; den Prometheus-Targetstatus unter
`http://127.0.0.1:9090/targets` pruefen.

Open WebUI's lokale Spracherkennung ist davon unabhaengig: der CachyOS-Container
nutzt `faster-whisper` mit `base` auf CPU. Windows-Diktat in Terminal/Wave
laeuft separat ueber Whisper Local und `large-v3-turbo` auf CUDA; Details zur
lokalen Tastenkombination stehen in `wsl-setup/docs/CACHYOS-WSL.md`.

## Wenn es klemmt

1. `./scripts/doctor.sh` - die Ausgabe endet mit einem konkreten Befehl.
2. `docs/troubleshooting.md` - typische Bilder erklaert.
3. `docs/backup-restore.md` - falls etwas weg ist.

## Nach einem Neustart automatisch

Das Repos verlaesst sich auf systemd: Units mit `WantedBy=default.target` und
aktivierter Linger (`loginctl enable-linger`) starten von selbst. Der Waechter
prueft ab 2 Minuten nach dem Start im Minutentakt. Was nach einem Neustart
geprueft werden sollte:

```bash
findmnt /srv/llm/ple-ext4 >/dev/null && echo PLE ok || ./scripts/47-setup-ple-storage.sh
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8001/health
```
