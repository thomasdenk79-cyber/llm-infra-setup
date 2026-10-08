# Betrieb

Kurzfassung fuer jede Woche, Ausfuehrliche fuer den ersten Tag.

## taeglich

```bash
./scripts/doctor.sh --short    # 10 Sekunden, sagt was zu tun ist
```

Nichts zu tun, wenn da `Alles in Ordnung.` steht.

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
| Chat (Open WebUI) | http://127.0.0.1:3001 | erster Account ist Admin |
| Gateway (OpenAI-kompatibel) | http://127.0.0.1:4000/v1 | Schluessel aus `credentials.txt` |
| Runtime direkt | http://127.0.0.1:8001/v1 | nur fuer Diagnose und lokale Tools |
| Grafana | http://127.0.0.1:3000 | |
| Prometheus | http://127.0.0.1:9090 | Targetspruefung: `/targets` |
| Dozzle | http://127.0.0.1:8080 | |

Der eigene Rechner ist per SSH erreichbar und die Ports sind nur auf dem
Loopback gebunden. Von einem anderen Rechner im Netz kommst du so hin:

```bash
ssh -L 3000:127.0.0.1:3000 -L 3001:127.0.0.1:3001 deinrechner
```

## Gateway-Fallback in drei Stufen

Der Gateway (Modellalias `qwen3.8-flash-next`) failovert ueber eine dreistufige Kette: primaer
Pennyroyal auf der Blackwell; nach drei Retries im Abstand von 5 s Stufe zwei,
Bonsai 2 27B auf der RTX 3500 Ada (~45 tok/s); wenn lokal gar nichts geht,
Stufe drei Luna ueber ChatGPT-Plus-OAuth. Nach 60 s Cooldown versucht der
Router erneut den Primaer. Die Schluessel liegen in
`~/.config/llm-infra/gateway.env`; Luna braucht keinen API-Schluessel - das
Geraet-Login legt seine Token unter `~/.config/llm-infra/chatgpt-tokens` ab,
das der LiteLLM-Container als `/etc/chatgpt-tokens` einhaengt. Geaendert wird
die Kette im Generator `scripts/60-install-gateway.sh`, nicht in der YAML.

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

### Waechter fuer den Gateway

```bash
./scripts/litellm-watchdog.sh --install     # systemd-Timer alle 5 Minuten
./scripts/litellm-watchdog.sh --reset       # Loopsperre nach 3 Neustarts loesen
```

Der Timer `llm-litellm-watchdog.timer` prueft die keyless Lebensanzeige
(`/health/liveliness`) plus einen 1-Token-Ruf durch den Router. Bei Ausfall:
laufende Anfragen der Runtime abfragen (`sglang:num_running_reqs`), GPU-Sperre
`${XDG_RUNTIME_DIR}/copilot-sm120-gpu.lock` per `flock -n` respektieren, dann
und nur dann ausschliesslich `litellm.service` neu starten - nie die Runtime.
Nach drei ergebnislosen Neustarts greift die Loopsperre. Protokoll:
`state/litellm-watchdog/watchdog.log`. Das ist die Gateway-Ergaenzung zum
Runtime-Waechter `scripts/runtime-watchdog.sh`; als Ueberwachungsluecke war er
bislang ein M4-artiger Fall aus `docs/GRAFANA-DRIFT-AUDIT-2026-10-08.md`
(Soll-Ist-Widerspruch ohne aktiven Nachweis).

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
cd ~/work/llm-infra-setup
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
