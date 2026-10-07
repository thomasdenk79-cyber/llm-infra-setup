# Projektstatus

Stand: 2026-10-07, Review- und Ausbauphase

## Aktuelle WSL-Stichprobe (2026-10-07)

Der Gateway-, Chat- und Beobachtungsstack lief in der CachyOS-WSL-Stichprobe.
`llm-node-exporter` protokollierte doppelte Dateisystem-Metriken unter
`/run/user`; das ist ein echter Exporterfehler und separat zu untersuchen.
Ein frueherer Pennyroyal-Startversuch scheiterte mit `CUDA_VISIBLE_DEVICES=1`,
weil PyTorch null sichtbare CUDA-Geraete meldete. Die aktuelle Quadlet-
Konfiguration verwendet eine GPU-UUID; der Container lief beim letzten Check
noch im Zustand `starting`, und `/health` war noch nicht erreichbar. Das ist
unabhaengig von Shellfarben oder Fish; keinen weiteren Kaltstart ausloesen,
solange der Ladevorgang laeuft.
Die Fehlerprotokolle enthalten fuer diesen Exit keinen OOM: Kernel-Journal
und `coredumpctl` waren leer. Prometheus zeigte in einer Stichprobe 119,9 GB
verfuegbaren WSL-RAM und den vollen 32-GiB-Swap; Pennyroyals systemd-cgroup
hatte eine gemeldete Spitze von 82,1 GB. Der Host-Verlauf ist daher kein
Beleg fuer RAM-Erschoepfung. Container-RAM wird von der aktuellen Grafana-
Konfiguration nicht historisiert. Fuer den naechsten Start sind CPU-Threads
und Loader auf 4, HiCache auf 8 GiB zurueckgestellt; Ergebnis noch offen.
Einzelheiten zu Laufzeitnamen und Grafana stehen in [`HANDOFF.md`](HANDOFF.md).
Aeltere Laufzeitangaben weiter unten sind historische Messungen, kein
Live-Healthcheck.

`llmlogs` zeigt die systemd-Journald-Eintraege im nativen Format mit den
Journal-Prioritaetsfarben und vermeidet doppelte, rohe Podman-Streams.
`NO_COLOR=1` deaktiviert Farben; Bedienung:
[`operations.md`](operations.md#logs-mit-llmlogs).

## Done

* Preflight erfasst Host, GPU, PCIe-Breite, Treiber, CDI, ZFS, Smart, Timer und
  User-Units in `state/preflight-report.txt` und der Kurzfassung `state/host-facts.txt`.
* Modell ist vollstaendig auf ZFS, Pruefung ueber Index- und Shard-Dateien,
  Hub-Revision in `versions.lock`.
* Pennyroyal v2.5.3 laeuft rootless als Quadlet, Bild per Digest gesperrt, API nur
  auf `127.0.0.1:8001`; Health-Endpunkt beantwortet, Smoke-Anfrage erfolgreich.
* PLE-Speicher ist als ext4-Loop mit **fest eingetragener fstab-Zeile**
  (`nofail`) vorbereitet; `scripts/47-setup-ple-storage.sh --verify` prueft das,
  und die Kennzahl `llm_ple_in_fstab` alarmiert, wenn der Eintrag fehlt.
* ZFS-Parameter begruendet gesetzt (lz4, recordsize 1 MiB, atime aus,
  `primarycache=metadata`, ARC-Deckel 16 GiB).
* Beobachtungsstufe ist vollstaendig im Einsatz: Prometheus, Grafana, Loki, Alloy,
  Dozzle, Portal, node_exporter (mit Host-Einhaengung), GPU-Exporter,
  Kennzahlen-Timer, vier eigene Dashboards mit menschenlesbaren Einheiten,
  Alarmregeln in `config/monitoring/alerts.yml`.
* Alloy sammelt Container-Protokolle inklusive Pennyroyal (Labels `container`,
  `image`, `job`), damit die Logsuche pro Dienst funktioniert.
* Gateway-Kette (PostgreSQL, LiteLLM, Open WebUI, Homepage) laeuft ohne GPU.
* Alle Zugangswerte sind Zufallswerte ausserhalb von Git; die alten
  Standard-Passwoerter sind aus dem Code entfernt, `make validate` prueft darauf.
* Deployment-Pfade sind vereinheitlicht: eine Installationsregel in `lib/units.sh`,
  drei Einstiegspfade (`deploy`, `deploy-non-gpu`, `deploy-ready`), ein sicherer
  Umschalter (`apply-runtime-unit.sh`) mit Schutz laufender Anfragen.
* Runtime-Waechter als User-Timer (warnt standardmaessig, Neustart nur nach drei
  Fehlversuchen und nur im Leerlauf, abschaltbar).
* Benchmark misst Vorlaufzeit und Schreibrate getrennt, mit Warmup, echter
  Parallelitaet, GPU-Kontext und Geschichtsdatei.
* `scripts/doctor.sh` prueft 13 Punkte und nennt zu jedem Fehler den passenden
  Befehl; Kurzform `make healthcheck`.
* `make drift` prueft, dass Generatoren die committeten Units exakt erzeugen;
  GitHub-Actions-Workflow laeuft bei jedem Push.
* Doku aufgeraeumt: Duplikate mit Gross-/Kleinschreibung sind entfernt,
  mkdocs-Navigation zeigt auf die aktuellen Dateien, 13 ADRs dokumentieren die
  Entscheidungen.
* Geschwindigkeit ist gemessen und eingeordnet (Thunderbolt x4/16 GT/s als
  Hauptgrenze), siehe `docs/performance.md` und ADR 0012.
* `versions.lock` enthaelt nur noch gepinnte Referenzen; der beobachtete Hoststand
  steht in `state/host-facts.txt`.

## Laufender Zustand (geprueft 2026-10-02)

* Runtime aktiv, `/health` 200, VRAM 94,9 von 97,9 GiB belegt.
* Alle Beobachtungsziele `up`: pennyroyal, node, gpu, loki, prometheus.
* Messungen: 157,88 Token/s (normal, 1 Anfrage), 119,01 Token/s (lang),
  242,47 Token/s (normal, 4 Anfragen). Vorlaufzeit 1,5 bis 4,5 Sekunden.
* Alarm `PCIeAnbindungReduziert` steht absichtlich auf "pending": er zeigt die
  echte Anbindungslimite des Rechners.

## Neu seit dem vorletzten Stand (2026-10-03)

* Native Blockflaeche fuer die Einbettungstabellen: ZFS-Volumen
  `zpcachyossrv/srv/ple-vol` (4K-Blockgroesse) mit ext4 (4K), `noatime`,
  `nofail`-Eintrag in `/etc/fstab`, Einhängepunkt `/srv/llm/ple-native`.
  Umzugswerkzeuge: `scripts/46-create-ple-volume.sh`, `scripts/49-migrate-ple.sh`,
  Seitenspeicher-Analyse `scripts/ple-preload.sh --status`.
  Warum kein echtes Partition: die Scheibe ist ein einziger 512-GiB-Datenträger
  in zwei ZFS-Pools, und ZFS-Vdevs lassen sich nicht verkleinern.
* Die Runtime-Startwerte sind als Umgebungsvariablen gesetzt (mem-fraction,
  Spekulationsschritte, sleep-on-idle, chunked-prefill, HiCache).
* `scripts/apply-tuning.sh` fuehrt die heisse Phase autonom aus: Pruefen,
  Sichern, Anwenden, Neustart, Messen, automatischer Rueckfaller.
* Richtigstellung: die Thunderbolt-Strecke ist **nicht** die Schreibraten-Grenze
  (gemessen 3-25 MB/s bei 61 % GPU-Auslastung und 275 W von 600 W Limit);
  Details in `docs/adr/0012-*.md`.
* Kapazitätsgrenzen fuer mehrere Sitzungen gemessen und dokumentiert
  (`docs/performance.md`: 524288 pro Anfrage, 824384 gemeinsam).

## Todo

1. Runtime einmal neu starten, damit die neue Unit (Healthcheck, Observability-Netz
   fuer Prometheus, `RestartSec`) aktiv wird - Zeitpunkt waehlen, wenn keine
   Anfragen laufen: `./scripts/apply-runtime-unit.sh --restart-only`.
2. PLE auf einer echten NVMe-Partition messen gegen die Loop-Datei (`PLE_BLOCK_DEVICE`).
3. DCGM-Exporter gegen nvidia-smi messen, danach Entscheidung welches bleibt.
4. Seccomp-Profil schreiben, das nur io_uring zulaesst (statt `unconfined`).
5. Komodo und Wartungstunnel erst mit echten Zugangsdaten aktivieren
   (`make komodo`, `make autossh`).
6. Woechentliche Regel aus Backup + Pruefung (`./scripts/restore.sh --check`).
7. KVM/libvirt als getrennte Phase, ohne GPU-Durchreichung.
8. Web-Verwaltung (Cockpit oder Podman Desktop) bewerten - erst nach Klärung der
   Frage, wer darauf zugreifen darf.

## Betriebsregeln

* Keine ZFS-Pools erstellen, zerstoeren oder umstrukturieren.
* Dauerhafte Aenderungen nur ueber dieses Repository.
* Geheimnisse bleiben ausserhalb von Git.
* Die Grafikkarte bleibt exklusiv beim Modell (ADR 0013).
