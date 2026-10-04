# Beobachtung einrichten und benutzen

Alles läuft rootless als User-Dienste; alle Ports sind nur auf
`127.0.0.1` gebunden.

## Einschalten

```bash
make monitoring
```

Das Skript `scripts/60-install-monitoring.sh` macht der Reihe nach:

1. Datenordner unter `~/.local/share/llm-infra/` anlegen
2. Zugangsdaten erzeugen, falls sie noch fehlen (`scripts/ensure-credentials.sh`)
3. GPU-Exporter-Unit erzeugen, falls sie fehlt
4. Alle Beobachtungs-Units installieren und starten
5. Kennzahlen-Timer aktivieren und einmal sofort sammeln
6. Pruefadressen ausgeben

Das selbe Skript ist auch in `make deploy-non-gpu` und `make deploy-ready`
enthalten - dreimal ausfuehren ist Absicht und aendert nichts.

## Was wo laeuft

| Dienst | Adresse | Pruefen mit |
|---|---|---|
| Grafana | http://127.0.0.1:3000 | Browser, Anmeldung: `./scripts/show-credentials.sh` |
| Prometheus | http://127.0.0.1:9090 | `curl -s 127.0.0.1:9090/-/ready` |
| Loki | http://127.0.0.1:3100 | `curl -s 127.0.0.1:3100/ready` |
| Dozzle | http://127.0.0.1:8080 | Browser |
| node_exporter | http://127.0.0.1:9100/metrics | `curl -s 127.0.0.1:9100/metrics \| head` |
| GPU-Exporter | http://127.0.0.1:9835/metrics | `curl -s 127.0.0.1:9835/metrics \| head` |

Targetspruefung im Browser: http://127.0.0.1:9090/targets - dort muss
`pennyroyal`, `node`, `gpu`, `loki` und `prometheus` auf `up` stehen.
`litellm` ist bewusst deaktiviert (Begruendung am Ende der Datei).

## Dashboards

Fuenf Dashboards liegen versioniert unter
`config/monitoring/grafana/provisioning/dashboards/` und werden von Grafana
automatisch geladen (Ordner "LLM Infrastructure"):

1. **LLM-Betrieb** - Vorlaufzeit, Schreibrate, laufende Anfragen, Warteschlange,
   Vorhersageguete der spekulativen Ausfuehrung, KV-Speichennutzung, Protokoll.
2. **GPU** - Auslastung, VRAM, Leistung, Temperatur, Takt, Drosselungsgruende,
   PCIe-Anbindung (Ist gegen Max).
3. **Host** - CPU gesamt/pro Kern, Load, Takt, RAM, Swap, Druck (PSI),
   Datendurchsatz und Auslastung der Platten, Netzwerk.
4. **Speicher** - ZFS-Poolzustand, Scrub, ARC-Groesse und Trefferquote,
   Dataset-Fuellstand und Kompression, NVMe-SMART, Modell- und PLE-Dateien,
   Zustand aller Dienste, Protokolle.
5. **Logs** - eine eigene Logansicht mit Dienstauswahl. Im Feld **Dienst** oben
   einen Container waehlen; Zeitraum und Aktualisierung stehen rechts oben.

Alle Achsen sind menschenlesbar skaliert (Prozent, GiB, MB/s, Millisekunden, °C).

## Eigene Host-Kennzahlen (llm_*)

Prometheus kommt von rootless Containern aus nicht an die Loopback-Ports des
Hosts. Deshalb sammelt `scripts/collect-host-facts.sh` alles, was nur der Host
weiss, in eine Textdatei, die der node_exporter einsammelt. Der Timer laeuft
alle 30 Sekunden.

Manuell ausfuehren und ansehen:

```bash
./scripts/collect-host-facts.sh
cat ~/.local/share/llm-infra/node-exporter/textfile/host-facts.prom
```

Wichtige Werte:

| Kennzahl | Bedeutung | Alarm |
|---|---|---|
| `llm_ple_in_fstab` | steht der PLE-Speicher im fstab? | 0 = Alarm (sonst Start nach Neustart kaputt) |
| `llm_ple_mounted` | ist der PLE-Speicher eingehaengt? | 0 = Alarm |
| `llm_model_shard_files` / `llm_model_incomplete_files` | Modell vollstaendig? | unter 150 bzw. uber 0 = Alarm |
| `llm_pcie_link_width` / `_max` | wie breit haengt die GPU? | deutlich kleiner = Hinweis |
| `llm_zfs_pool_health` | 1 = ONLINE | sonst Alarm |
| `llm_smart_*` | NVMe-Zustand (braucht sudo) | Alarm bei kritischer Warnung, Abnutzung ueber 90 % |
| `llm_unit_active{unit=..}` | laeuft ein Dienst? | - |
| `llm_benchmark_*` | letzte Messung | - |

Ohne sudo-Eintrag liefert das Skript alle anderen Werte und
`llm_smart_available 0`. Wer SMART will, ergaenzt eine passende
sudoers-Regel fuer `smartctl` - bewusst nicht automatisch, weil sudoers
ein kritischer Ort ist.

## Protokolle

Alloy liest die Container ueber den Podman-Socket (`%t/podman/podman.sock`)
und schiebt sie zu Loki. Die strukturierte Ansicht ist direkt erreichbar:
`http://127.0.0.1:3000/d/llm-infra-logs/logs`. Dort waehlt man oben den Dienst
und den Zeitraum. Fuer freie Abfragen kann man weiterhin Grafana Explore mit
der Datenquelle Loki verwenden:

Fuer die haeufigste Abfrage gibt es auf der Homepage den Eintrag
**Runtime-Logs**. Er oeffnet die Pennyroyal-Logs bereits mit einem kurzen
Zeitraum und zehn Sekunden Aktualisierung. **Dozzle** zeigt parallel die
rohen Live-Ausgaben aller Container.

```
{container="pennyroyal"}                       alles von der Runtime
{container="pennyroyal"} |= "error"             nur Fehlerzeilen
{job="containerlogs"} |= "CUDA out of memory"   ueber alle Container
```

Voraussetzung: `systemctl --user enable --now podman.socket` (macht `make podman`).

## Alarme

Regeln liegen in `config/monitoring/alerts.yml` und werden von Prometheus
ausgewertet; Grafana zeigt sie unter "Alerting". Der Weg ist bewusst Prometheus
und nicht nur Grafana: die Regeln liegen im Repository und sind ohne
Grafana-Export pruefbar.

Die wichtigsten Regeln:

* `PennyroyalNichtErreichbar` - 20 Minuten, weil ein Kaltstart 15 Minuten dauert
* `PennyroyalOhneFortschritt` - Anfragen laufen, aber keine Token
* `PleSpeicherFehlt` / Modell-Shards fehlen - Start nach Neustart gesichert
* `FestplatteVolll` (<10 % auf `/` oder `/srv`), `ZFSPoolNichtOnline`
* `PCIeAnbindungReduziert`, `GPUWarmeGrenze`
* `EinzelrequestZuLangsam` (<25 Token/s ueber 10 Minuten)
* `NVMeKritisch` (bewusst ohne Alarmhysterie bei rohen Nutzungswerten)

## GPU-Exporter: zwei Moeglichkeiten

```bash
make gpu-exporter                      # Standard (nvidia-smi), im Betrieb sicher
GPU_EXPORTER=dcgm ./scripts/65-install-gpu-exporter.sh   # mehr Messwerte, kann die Inferenz bremsen
```

`nvidia-smi` (Version 1.4.0) ist der Default: 115 Messwerte, davon nutzt das
Dashboard Temperatur, Takt, VRAM, Leistung, Auslastung und Drosselung.
DCGM liefert mehr (unter anderem Fehlerzaehler und PCIe-Durchsatz); es erst nach
einer Baseline aktivieren.

## LiteLLM-Metriken sind deaktiviert

Der offizielle LiteLLM-Container liefert auf `/metrics` nur 404, weil im Bild
kein `prometheus-client` steckt. Der Job ist in
`config/monitoring/prometheus.yml` auskommentiert und beschreibt dort die drei
Schritte zur spaeteren Freischaltung.

## Troubleshooting kurz

| Bild | Ursache | Befehl |
|---|---|---|
| Target `pennyroyal` down | Prometheus nicht im Inferenz-Netz | `./scripts/apply-runtime-unit.sh` |
| `llm_smart_available 0` | sudo braucht Passwort | sudoers-Eintrag oder hinnehmen |
| Grafana startet nicht | Podman-Secret fehlt | `./scripts/ensure-credentials.sh` |
| Keine Logzeilen | podman.socket aus | `systemctl --user enable --now podman.socket` |
| Textdatei wird ignoriert | eine Familie ohne TYPE-Zeile | `./scripts/collect-host-facts.sh` erneut |
