# Aenderungsprotokoll
## 2026-10-08 – Gateway-Haertung: Monitoring-Auth, Waechter, Drill

- Root-Cause 401-Welle: interne Prueflaeufer ohne gueltigen Bearer trafen die
  master-key-geschuetzten Endpunkte /health und /metrics: der Repo-eigene
  healthcheck.sh und llmctl prueften /health (401 ohne Key -> "Gateway nicht
  erreichbar" als false negative), doctor.sh nutzte den Liveness-Alias, dazu
  Client-Sondierungen aus dem Inferenz-Netz (Open-WebUI-Muster /api/tags,
  /props, /version unmittelbar vor jeder "Malformed"-Zeile; rotierende
  Container-IPs 10.89.1.x). Folge: "No api key passed in." / "Malformed API
  Key ... Bearer prefix" mit Traceback im Journal. Befund 12h-Journal: 57x
  "No api key", 8x "Malformed". Kein aktiver Prometheus-Litellm-Target im
  Live-Config (ueber /api/v1/targets verifiziert); /metrics liefert selbst mit
  gueltigem Key 404 (Chainguard-Image ohne prometheus-client). Fix: alle
  internen Tests auf das keyless /health/liveliness umgestellt
  (healthcheck.sh zeigte "Gateway nicht erreichbar" als false negative trotz
  200er Liveliness), Prometheus-Vorlage dokumentiert keyless Liveness-Scrape
  und Bearer-nur-als-Secret-Datei. Keine Secretwerte im YAML (validate rc=0,
  promtool SUCCESS).
- Neu: scripts/litellm-watchdog.sh + systemd/llm-litellm-watchdog.{service,
  timer} (5 min): Liveliness + 1-Token-Smoke; restartet bei Ausfall ausschliesslich
  litellm.service, mit running_reqs-Schutz, GPU-Lock-Guard (flock -n auf
  ${XDG_RUNTIME_DIR}/copilot-sm120-gpu.lock) und 3er-Loopsperre. Guard-Pfad
  getestet (Sperre belegt -> keine Aktion, rc=0). Timer aktiv.
- Neu: scripts/litellm-failover-drill.sh - Wegwerf-Container litellm-drill
  (:4013) mit totem Primaer (:4099); beweist KETTE OK. Letzter Lauf:
  kettenuebergabe 22,2s -> bonsai-2-27b (tok=2), bonsai direkt 0,27s, luna
  direkt 1,73s (tok=5, 'Sure'). Erstbeweis der Kette: 9,78s gesamt, ~45 tok/s.
  Luna braucht temperature-freie Anfragen (400 Bad Request sonst) - im Drill
  beruecksichtigt.
- Hermes-"Clean EOF, no finish_reason": zwei Klassen. (1) Restart-Artefakt:
  die Warnungen 11:52:33/11:54:02/11:54:23 liegen unmittelbar um den
  litellm-Neustart 11:51:39-11:51:53 (Streams, die den Container-Stopp
  ueberlebten, enden sauber ohne Schlusspaket). (2) Vereinzelte Faelle ohne
  Neustartfenster (11:40-11:50, 11:10, 09:13, 08:17) - ob clientseitige
  Abort-Streams oder ein Upstream ohne finish_reason endet, bleibt offen;
  kein Muster eines reproduzierbaren Kettendefekts.
  Doku beschreibt die Unterscheidung (Neustartfenster pruefen, sonst Kette
  per Drill durchmessen).
- Doku: operations.md (Drill, Waechter, Luna-Token-Persistenz,
  Monitoring-vs-Key-Endpunkte), troubleshooting.md (401-Klasse, Luna-Token,
  Clean EOF), monitoring.md Beobachtungsliste aktualisiert.
- Querverweis: schliesst eine M4-artige Luecke (Ist-vs-Soll ohne aktiven
  Nachweis) aus docs/GRAFANA-DRIFT-AUDIT-2026-10-08.md; Audit selbst unveraendert.

## 2026-10-08 – Bonsai 2 als LiteLLM-Fallback

- Bonsai 2 27B PTQ1_0 wird auf der RTX 3500 Ada durch Prism-llama.cpp als rootless WSL-Quadlet auf Port 8082 bereitgestellt (8192 Kontext, Q8-KV).
- LiteLLM-Fallback unter separatem Modellnamen `bonsai-2-27b`; die Primaergruppe `qwen3.8-flash-next` verweist ueber `router_settings.fallbacks` darauf. Generator nutzt optionalen `FALLBACK_API_KEY` aus der lokalen Runtime-Environment-Datei; kein Key-Wert im Git.
- Verifikation: `make validate` bestanden; separater Proxy mit totem Primaer gab eine Bonsai-Completion zurueck (45,1 Token/s). Live-Gateway neu gestartet, Health 200; Pennyroyal ebenfalls Health 200. Blackwell-VRAM blieb bei ca. 93,2 GiB.

## 2026-10-08 – Grafana: Dashboards zeigen wieder Daten

- Ursache: Prometheus-Container ohne Netz-Alias `prometheus`; die
  Grafana-Datenquelle `http://prometheus:9090` lief in einen DNS-Fehler
  (`lookup prometheus ... no such host`), alle Panels "no data" obwohl alle
  Scrape-Ziele `up` waren.
- Zusatzfehler: Dashboard-JSONs referenzierten nicht-existente Datenquellen-UIDs
  (`prometheus`, `loki`) bzw. vertauschte UIDs (01); `rotate-secrets.sh`
  exec-te in den Container-Namen `grafana` statt `systemd-grafana` und konnte
  das Admin-Passwort deshalb nie in der Grafana-DB realignen; Grafana 12
  Passwort-Politik lehnte das generierte Hex-Passwort ab.
- Fix: `NetworkAlias=prometheus` (quadlet + installierte Unit), feste
  `uid:`-Felder in `datasources.yml`, alle Panel-UIDs normalisiert,
  PCIe-Panel auf `nvidia_smi_pcie_link_*` umgestellt, rotate-secrets korrigiert.
- Verifikation: 79/95 Panel-Abfragen liefern ueber `/api/ds/query` Daten
  (vorher 0/95 ueber Prometheus-Proxy); Loki-Log-Panels direkt gegen
  `/loki/api/v1/query_range` bestaetigt. Restluecken = WSL-Umgebungsgrenzen
  (ZFS/SMART/Takt nur auf echtem Host), dokumentiert unter Datengrenze.


## Diagnose WSL/Pennyroyal (2026-10-07)

* WSL-Startwerte fuer Loader, OMP, Torch-Compile und Build auf je 4 begrenzt;
  HiCache von 32 auf den Projektstandard 8 GiB zurueckgesetzt. Das ist ein
  konservativer Diagnoselauf, keine Leistungsoptimierung.
* Ein Startfehler war nachweislich kein OOM: PyTorch beendete sich mit Exit 1,
  weil `CUDA_VISIBLE_DEVICES=1` im Container kein CUDA-Geraet sichtbar machte.
* Kernel-Journal und Coredumpctl zeigten keine OOM-Kills oder Core Dumps.
  Prometheus erfasst Host-RAM/Swap, aber keine Pennyroyal-Container-RAM-Zeitreihe.

## Unveroeffentlicht (Review- und Ausbauphase, 2026-10-02)

Behoben (Zustand des Rechners war betroffen):

* PLE-Speicher fehlte nach einem Neustart: der `nofail`-Eintrag in `/etc/fstab`
  wurde nie geschrieben, obwohl Skript und Doku das behaupteten. Jetzt wird er
  gesetzt und durch `--verify` sowie die Kennzahl `llm_ple_in_fstab` ueberwacht.
* Prometheus konnte die Runtime nicht erreichen (zwei getrennte Netze).
  Prometheus haengt jetzt an beiden Netzen, die Runtime bleibt einhuehnig.
* Grafana hatte keinen Passwort-Zugriff mehr (leeres Podman-Secret) und haette
  ohne Secret gar nicht gestartet; Secret wird jetzt zuverlaessig erzeugt.
* Die Runtime-Unit wurde ohne Healthcheck-Befehl und ohne `RestartSec` gestartet;
  Haengen fuehrte zu keinem Neustart. Jetzt `HealthCmd`, `RestartSec`,
  `TimeoutStartSec` und ein optionaler Waechter-Timer.
* `./setup.sh` ueberschrieb die OpenCode-Konfiguration ungefragt; jetzt nur noch
  anlegen, wenn keine Datei existiert, sonst Vorlage daneben.
* `flock` meldete Erfolg, obwohl ein anderer Lauf aktiv war (Exit 0 statt 75).
* Zwei Deploy-Skripte installierten dieselben Units unterschiedlich; jetzt eine
  gemeinsame Installationsregel in `lib/units.sh` inklusive Platzhalterersetzung.
* Nach der Umbenennung von Einheiten blieben Altdateien im User-Ordner und
  bringen sich gegenseitig zum Neustart; Deploy laeuft jetzt
  `prune_legacy_units`.
* Prometheus-Dienst lief als `nobody` und konnte die Schluesseldatei nicht lesen
  (`User=root`, Begruendung im Quadlet).
* GPU-Exporter 1.2.1 stuerzte mit dieser Treiberversion ab; 1.4.0 arbeitet sauber
  (115 Messwerte) und wurde in Betrieb genommen.
* Alloy sammelte keine Logs, weil Relabel-Regeln und Ziel-Labels fehlten.
* Die eigenen Host-Kennzahlen wurden von node_exporter verworfen, weil
  Typangaben fuer einige Familien fehlten; Assemble-Schritt ergaenzt sie jetzt.
* `start_units` blockierte bei fehlschlagenden Units (`--no-block` + Rueckmeldung).
* SMART meldete falsche Einheiten (1,2 TB statt 50 TB) und fehlende
  Temperaturwerte; JSON-Pfad berichtigt.
* Die Pruefung `47 --verify` meldete "nicht beschreibbar" auf einem rein
  lesenden Einhängepunkt; sie prueft jetzt Lesbarkeit und Inhalt.

Sicherheit und Zugangswerte:

* Alle Zugangswerte sind jetzt Zufallswerte ausserhalb von Git; die vier alten
  Standardpasswoerter sind aus dem Code entfernt, `make validate` prueft darauf.
* Wartungstunnel: nur noch ein eingetragener Schluessel statt ganz `~/.ssh`,
  kein Paketnachbau bei jedem Start, Platzhalterhost fuehrt zum Abbruch.
* Komodo-Periphery bricht ohne echten Server und Schluessel ab und erhaelt den
  Podman-Socket.
* Weltweit schreibbare Ordner (0777) durch 0755 mit Eigentruemer ersetzt.

Ausbau (fehlt in der Vorversion, im Masterprompt aber verlangt):

* node_exporter mit Host-Einhaengung, GPU-Exporter, eigener Kennzahlensammler
  inkl. systemd-Timer, SMART/NVMe-Werte.
* Vier eigene Dashboards (LLM-Betrieb, GPU, Host, Speicher) mit deutschen Titeln
  und menschenlesbaren Einheiten statt eines Panel-Rumpfes.
* Alarmregeln (`config/monitoring/alerts.yml`), inklusive Alarm auf fehlenden
  PLE-Eintrag im fstab.
* Benchmark misst Vorlaufzeit und Schreibrate getrennt, mit Warmup, echter
  Parallelitaet, GPU-Kontext, Geschichtsdatei und Sollwert-Pruefung.
* `scripts/backup.sh` und `scripts/restore.sh` mit Pruefsummen, pg_dump,
  ZFS-Snapshot und Testlauf.
* `scripts/doctor.sh` als gefuehrter Diagnose-Lauf (13 Pruefpunkte, jeweils mit
  dem naechsten Befehl), neue Einstiegspfade fuer alle Faelle.
* `scripts/wait-for-runtime.sh`, konfigurierbare Wartezeit statt starrer 15 Minuten.
* `scripts/check-drift.sh` plus GitHub-Actions-Workflow (validate, drift, Doku).
* Dokumentation: Duplikate mit Gross-/Kleinschreibung entfernt, mkdocs-Navigation
  repariert, ADRs 0009-0013 ergaenzt, neue Seiten `performance.md`,
  `backup-restore.md`, vollstaendige `monitoring.md`.
* Grundregel "die Grafikkarte gehoert dem Modell" (ADR 0013) dokumentiert.
* Messprotokoll zur Durchsatzfrage: 157,88 / 119,01 / 242,47 Token/s und die
  PCIe-Ursache (x4 @ 16 GT/s) statt Modell- oder GPU-Schuld.
