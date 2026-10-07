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
