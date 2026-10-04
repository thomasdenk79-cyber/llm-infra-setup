# Aenderungsprotokoll

## Unveroeffentlicht (Runner-Review, 2026-10-04)

Behoben (Runner- und Benchmark-Pfade, keine Runtime-Units angefasst):

* `scripts/benchmark.sh`: `config/host.env` ueberschrieb still den vom
  Variantrunner uebergebenen `PENNYROYAL_PORT`/`BENCHMARK_MODEL`; Varianten
  wurden dadurch gegen Port 8001 gemessen statt gegen ihren eigenen Port.
  Aufruferwerte gewinnen jetzt. Zusätzlich beendet sich das Skript mit
  Fehlerstatus, wenn Anfragen fehlgeschlagen sind (vorher Exit-Status 0
  trotz 0 erfolgreicher Anfragen und damit falsche `passed`-Markierung der
  Variante A im Lauf 20261004T040547Z).
  Metrikparsung nutzt jetzt das letzte Feld (robust gegen Label-Leerzeichen).
* `scripts/run-ple-variant-matrix.sh`: Drain blockierte dauerhaft 30 Minuten,
  wenn gar kein Metrikdienst antwortete oder die eigenen Heiler-Skripte
  liefen; jetzt blockieren nur noch echte `opencode run`/`codex exec`-Prozesse.
  Restore-Readiness prüft Turbo-C6 jetzt auf dessen echtem Host-Port 8002
  (vorher Default 8001 = 45-Minuten-Haenger bei jedem Matrix-Ende).
  Readiness bricht nicht mehr sofort ab, wenn der Container noch fehlt
  (Hochfahr-Race nach `systemctl start`).
* `scripts/ple-heal-failure.sh`:   Qwen-Review wartete bis zu 90 Minuten blind
  auf 8001/8002 und konnte waehrend eines laufenden Matrixlaufs der
  Messung GPU-Zeit wegnehmen. Jetzt: zuerst begrenztes Warten, bis die
  Matrix die GPU frei gibt, dann maximal 20 Minuten Health-Pruefung,
  zusaetzlich LiteLLM-Pruefung (Port 4000) vor dem Review.
* `scripts/ple-matrix-supervisor.sh`: Submission-Race nach `systemd-run`
  (Unit noch nicht registriert) konnte die veraltete `summary.csv` des
  Vorlaufs als Ergebnis der neuen Runde deuten; jetzt wird Registrierung
  abgewartet und nur ein seit Rundenstart neu angelegtes Laufverzeichnis
  akzeptiert, fehlende `summary.csv` zaehlt als Fehler statt als Erfolg.
* `scripts/ple-research-audit.sh` und `scripts/ple-matrix-healer.sh`:
  Vorpruefung (Produktionsruntime 8001/8002 und LiteLLM 4000 erreichbar,
  Matrix nicht laufend) verhindert stundenlanges lautes Laufen von
  Qwen-Sessions gegen eine tote API.
* `scripts/benchmark_probe.py`: abgebrochene Streams (`RemoteDisconnected`,
  `ConnectionError`, HTTPException) wurden nicht abgefangen; Schaetzung der
  Tokenzahl aus SSE-Chunks ist jetzt mit `tokens_from_chunks` gekennzeichnet.

## Unveroeffentlicht (Review- und Ausbauphase, 2026-10-02)

Neu (nur Doku, keine Live-Aenderung):

* `docs/ple-graph-analysis.md` buert die Ursachenanalyse der Varianten A-D:
  unbedingter `wait_stream`-Join auf `_prefetch_stream` als Grund des
  `cudaErrorStreamCaptureIsolation`, Breakable-Pflicht fuer den SSD-PLE-Pfad,
  Geschwindigkeitsprognose (B vor D, C als Referenz), ausserdem der Nachweis
  aus dem Pennyroyal-Bild, dass dessen `ssd_stream`-Plugin-Hook
  (Erfassungserkennung, Ereignissynchronisation, Slot-Staging) graph-sicherer
  ist als der eigene Turbo-Lader. Bildinhalt per `podman cp` geprueft, der
  Container wurde nie gestartet.

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
