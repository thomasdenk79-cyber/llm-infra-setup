Zuletzt gesichert: 2026-10-04T00:04:16+02:00 durch `scripts/session-checkpoint.sh`

# Arbeitsstand und Uebergabe

**Diese Seite ist der Fortsetzungsanker.** Wenn eine Sitzung abreisst, der Rechner
neu startet oder ein anderer Agent uebernimmt: hier steht, was gilt. Regel aus
`AGENTS.md`: Nach jedem abgeschlossenen Schritt `./scripts/session-checkpoint.sh`
(a ktualisiert diese Seite, committet, pusht). Das Repository ist das Backup.

## 1. Sofortlage (Kurzfassung fuer den naechsten Leser)

```bash
cd ~/work/llm-infra-setup
./scripts/doctor.sh          # gefuehrte Diagnose, nennt den naechsten Befehl
./scripts/session-checkpoint.sh --status    # was ist noch ungesichert?
```

* Runtime laeuft auf Pennyroyal v2.5.3, Modell `Qwen3.8-Flash-Next-NVFP4`,
  Bild-Digest in `versions.lock` gesperrt.
* Ports nur auf `127.0.0.1`: Runtime 8001, Gateway 4000, Chat 3001, Portal 3002,
  Grafana 3000, Prometheus 9090, Dozzle 8080, node_exporter 9100, GPU-Exporter 9835.
* Zugangsdaten: `./scripts/show-credentials.sh` (Datei `~/.config/llm-infra/credentials.txt`).
* Beobachtung ist vollstaendig in Betrieb: 5 Prometheus-Ziele `up`, 4 Dashboards,
  22 Alarmregeln, Loki-Logs je Container.

## 2. Was in dieser Runde fertig wurde (Auswahl)

* PLE-Speicher hat jetzt einen echten `nofail`-fstab-Eintrag (vorher: Start nach
  Neustart kaputt) und ist zusätzlich auf ein **natives ZFS-Volumen** umgezogen:
  `zpcachyossrv/srv/ple-vol` (80 GiB, volblocksize 4K) → ext4 (4K, `noatime`) →
  `/srv/llm/ple-native`. Tabelle 47,68 GiB kopiert und stichprobengeprüft.
* Prometheus haengt an beiden Netzen und sieht `pennyroyal:8001` (vorher dauerhaft down).
* Grafana-Secret, Zufalls-Passwoerter, `rotate-secrets.sh`; `doctor.sh`;
  `apply-runtime-unit.sh` mit Schutz laufender Anfragen; Runtime-Waechter.
* node_exporter mit Hostsicht, GPU-Exporter 1.4.0, SMART, PCIe-Breite,
  eigene `llm_*`-Kennzahlen inkl. `llm_ple_in_fstab`.
* Benchmark misst Vorlaufzeit und Schreibrate getrennt (`state/benchmarks/history.csv`).
* Backup/Rueckgabe mit Pruefsummen und `pg_dump`; GitOps-Pfad; `make drift`.
* Doku: Duplikate entfernt, mkdocs strict laeuft, ADRs 0009-0013,
  `docs/COMPLIANCE.md` (Abgleich mit `setup_prompt.md`).
* **Richtigstellung:** Thunderbolt ist *nicht* die Schreibraten-Grenze
  (gemessen 3-25 MB/s bei 61 % Auslastung, 275 W von 600 W). Siehe ADR 0012.
* Online-FP8 erklaert und als Schalter angelegt: es **ersetzt kein NVFP4**, es
  quantisiert nur die verbliebenen BF16-Projektionen (`PENNY_ONLINE_FP8`).
* Stellgroessen der Laufzeit sind jetzt ueber `config/host.env` erreichbar
  (aufgenommene Anfragen - Bild-Standard war 4! - Zustandsslots,
  Obergrenze Zeichenspeicher, gezeichnete Batchgroesse, Aktivierungsspeicher,
  Speulationstiefe, sleep-on-idle, mem-fraction).
* Freigabe der Rechenkarte fuer das Modell: `45-configure-kwin-egpu.sh --modus llm`
  (Desktop auf Intel) und `44-isolate-blackwell.sh` (udev, Anzeigepfad zu, CUDA an,
  mit Selbsttest und Selbst-Rucknahme).
* Qualitaetspruefung `scripts/quality_check.py`; Baseline 4/4 bestanden.

## 3. Heisse Phase (Neustart der Laufzeit)

Der Neustart ist der einzige Schritt, der Sessions trennt. Ablauf:

```bash
./scripts/apply-tuning.sh --nur-plan                    # anzeigen
./scripts/apply-tuning.sh --profil sweet --nur-plan     # empfohlen: 4 Anfragen, 16 Plaetze
./scripts/apply-tuning.sh --profil aggressiv            # 8 Anfragen, 5/1/8, HiCache 16
./scripts/apply-tuning.sh --profil maxkv                # 1 Anfrage, graph-reservensicher
./scripts/apply-tuning.sh --profil c16                 # Belastung: 16 Anfragen, 64 Zustandsplaetze
./scripts/apply-tuning.sh --zurueck                     # zur letzten Sicherung
./scripts/session-checkpoint.sh                         # Ergebnis sichern
```

* Vorher laeuft `benchmark.sh normal 1` als Baseline, nachher dieselbe Messung;
  faellt sie unter 90 %, stellt das Skript selbststaendig zurueck.
* Protokoll: `state/tuning/<stempel>/report.txt`, gesicherte Dateien daneben.
* Erwartung (redlich): eine Anfrage 160-200 Token/s, Summe der Schreibraten bei
  vier Anfragen etwa 370 statt 158, Gesamtdurchsatz des Skripts (mit Vorlaufzeit)
  rund 250-300. `maxkv` kann den gemeinsamen Zeichenspeicher von 824.384 auf
  etwa 1.000.000 Token heben - exakt erst nach dem Start sichtbar
  (`sglang:max_total_num_tokens`).

## 4. Noch offen

Fuer die Skalierungsmessung gibt es das Profil `c16`: 16 aufgenommene Anfragen, 64 Mamba-Slots (vier je Anfrage), CUDA-Graph-Maximum 8 und `chunked-prefill=8192`. Nach dem aktuellen Kaltstart zuerst `scripts/benchmark.sh normal 1`, `2`, `3`, `4`, `6` und `8` ausfuehren; danach mit `make tune-c16-an` neu starten und `scripts/benchmark.sh normal 16` messen. Jeder Profilwechsel startet die Runtime neu.

0. Gemessener Zusammenhang: vier Zustandsplaetze je Anfrage (Log `mamba num: 4`),
   24 Plaetze gesamt bei Bild-Standard, 2262 MiB VRAM frei. Das Startskript bricht
   ab, wenn `MAX_MAMBA_CACHE_SIZE < 4 x MAX_RUNNING_REQUESTS`. Erklaerung und
   Zahlen in `docs/performance.md`.
1. Nach dem Tuning: `make quality-lang` (Merk-Aufgaben bis 300.000 Prompt) und
   `make quality-vergleich`; DCGM-Exporter gegen nvidia-smi vergleichen.
2. Neustarttest: fahren alle Units nach Reboot hoch? fstab-Loop und -zvol prüfen.
3. `backup.sh`: Tarntel fuer `~/.local/share/llm-infra/grafana` scheitert an
   Rechten ( png/pdf ) und ZFS-Snapshot braucht Berechtigung - loesen.
4. Eigenes Seccomp-Profil statt `unconfined` fuer den Inferenz-Container.
5. Komodo und Wartungstunnel erst mit echten Zielangaben aktivieren
   (`make komodo`, `make autossh`).
 6. Virtueller Gateway-Schluessel pro Agent + Test (Auftragstext Abschnitt 22/40-8).
 7. spaeter: zweites Modell, Azure-Fallback, KVM - siehe `AGENTS.md`.
 8. Turbo-Varianten A-D sind vorbereitet, aber **keine einzige ist getestet**
    (kein Build, kein Start, kein Benchmark). Auftrag und Ablauf:
    `docs/variant-test-prompt.md` und `docs/variant-comparison.md`.


## 5. Wo was liegt

| Inhalt | Ort |
|---|---|
| Diagnose | `scripts/doctor.sh`, Kurzform `scripts/healthcheck.sh` |
| Tuning und Rueckfaller | `scripts/apply-tuning.sh`, `state/tuning/` |
| Umgebungsvariablen | `config/host.env.example` (erklaert), `config/host.env` (lokal) |
| Laufzeit-Rezept mit Stellgroessen | `config/pennyroyal/serve-flash-next-frspec.sh` |
| Messreihen | `state/benchmarks/*.json`, `history.csv` |
| Qualitaetspruefungen | `state/quality/` |
| PLE-Umzug | `scripts/46-create-ple-volume.sh`, `scripts/49-migrate-ple.sh` |
| Kartentrennung | `scripts/44-isolate-blackwell.sh`, `scripts/45-configure-kwin-egpu.sh` |
| Sichern/Pushen | `scripts/session-checkpoint.sh` |
| Abgleich mit dem Auftrag | `docs/COMPLIANCE.md`, Auftragstext `setup_prompt.md` (Abschnitt 43) |

## 6. Grundregeln (gelten weiter)

* Die Grafikkarte gehoert dem Modell: TP1, keine weiteren GPU-Nehmer (ADR 0013).
* Laufende Anfragen sind Schutzgut: Unit-Aenderungen nur ueber
  `apply-runtime-unit.sh`; Neustart ist ein ausdruecklicher Schritt.
* Nutzerdateien nicht ueberschreiben; Vorlagen legen sich daneben.
* Keine `zfs destroy`-, `zpool`- oder Formatier-Befehle ohne Bestaetigung.
* Keine Geheimnisse im Git; Beispiele bleiben Platzhalter.

## Notiz 2026-10-03T14:05:00+02:00

Produktionsprofil `c6-production` angelegt, noch nicht gestartet: Online-FP8,
6 Requests, 36 Mamba-Slots, Graph-Maximum 6, KV-Obergrenze 1.048.576, NVMe-PLE
und HiCache 16 GiB. Fuer diesen Test wird `PENNY_MEM_FRACTION_STATIC` aus
`config/host.env` entfernt, damit der aktuelle Runtime-Default profiliert; die
vorherige Annahme, 0.992 sei ursächlich, ist nicht belegt. Anwenden mit
`./scripts/apply-tuning.sh --profil c6-production --ohnemessung`.

## Notiz 2026-10-03T08:09:39+02:00

Kurz vor der heissen Phase: Kartentrennung, KV-Knospen, Qualitaetspruefung und Sicherungsmechanik sind drin.

## Notiz 2026-10-03T08:11:47+02:00

Zustandsplaetze je Anfrage gemessen (4); Profile sweet/aggressiv/maxkv neu dimensioniert; Guard im Rezept

## Notiz 2026-10-03T08:21:27+02:00

PREFILL_CHUNK_SIZE-Unbound-Fehler im Runtime-Rezept behoben; Default und Host-Override frueh definiert

## Notiz 2026-10-03T08:22:00+02:00

Der erste Neustart scheiterte wiederholt, weil `set -u` in
`config/pennyroyal/serve-flash-next-frspec.sh` den Fallback
`${PREFILL_CHUNK_SIZE}` auswertete, bevor die Variable definiert war. Der
Fallback ist jetzt frueh `PENNY_CHUNKED_PREFILL_SIZE` oder `4096`; der spaetere
Hardcode wurde entfernt. Commit `879072c` ist gepusht. Danach wurde die Unit
automatisch neu gestartet; aktuell ist `pennyroyal.service` aktiv und der
Container `pennyroyal` laeuft im Kaltstart (PLE-Pruefung/Modellstart), daher kann
Port 8001 noch kurzzeitig resetten. Pruefen mit:

```bash
systemctl --user is-active pennyroyal.service
podman ps --filter name=pennyroyal
curl -fsS http://127.0.0.1:8001/health
```

## Notiz 2026-10-03T08:23:11+02:00

Runtime-Rezeptfehler dokumentiert; Pennyroyal nach Fix im Kaltstart und PLE-Check

## Notiz 2026-10-03T08:30:08+02:00

c16 Belastungsprofil fuer 16 parallele Anfragen und Benchmark-Sweep dokumentiert

## Notiz 2026-10-03T08:34:56+02:00

Performance-Review: CUDA-Graph-, Memory-Saver- und Sleep-Optionen tatsaechlich an SGLang uebergeben

## Notiz 2026-10-03T08:36:38+02:00

Kontextziel-Argument fuer Benchmarks ergaenzt; Fixes vor Runtime-Neustart gesichert

## Notiz 2026-10-03T08:37:21+02:00

Ergebnis der heissen Phase (Profil sweet)

## Notiz 2026-10-03T08:52:42+02:00

Mehrstuendigen Performance-Sweep fuer Profile, Kontextgroessen und Parallelitaet hinzugefuegt

## Notiz 2026-10-03T09:02:28+02:00

Benchmark-Einzelmessung und Sweep-Metrikformat nach Architektur-Review repariert

## Notiz 2026-10-03T09:03:48+02:00

Parallel-Benchmarks gegen Prefix-Cache-Artefakte abgesichert; Sweep-CSV-Schema versioniert

## Notiz 2026-10-03T09:16:58+02:00

Runtime-Fix validiert: Memory-Saver ohne expandable_segments; Logsammler shellcheck-sauber

## Notiz 2026-10-03T09:44:11+02:00

Performance-Messmatrix mit Stabilitaets-, Kontext-, KV-, PLE- und Online-FP8-Achsen dokumentiert

## Notiz 2026-10-03T09:50:00+02:00

Die Runtime ist wieder `healthy` und `/health` antwortet. Ein vorheriger
Startfehler war eine falsche lokale Kombination: `PENNY_ENABLE_MEMORY_SAVER=1`
mit `PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True`; TorchMemorySaver brach
dadurch vor dem Modellstart ab. Das Rezept entfernt `expandable_segments` jetzt
nur im Memory-Saver-Modus (Commit `bd126e0`). Die Forschung wird fortgesetzt:
solche Punkte gelten als konfigurationsbedingte Fehlerfaelle und werden in der
Messmatrix separat erfasst, nicht als Modellgrenze verworfen.

Der aktuelle Host hat etwa 15 GiB `MemAvailable` und rund 5 GiB Swap in Nutzung;
RAM-PLE mit zusaetzlich ca. 48 GiB wird daher erst nach einer kontrollierten
Vorpruefung getestet. NVMe-PLE ist die laufende Referenz. Vor dem naechsten
Sweep pruefen: `curl -fsS http://127.0.0.1:8001/health`, `nvidia-smi`,
`free -h`, `pgrep -af 'qemu|kvm'`. Ergebnisse, Fehlerlogs und Profilwechsel
bleiben in Loki, `state/benchmarks/` und `state/benchmarks/sweep/` erhalten.

## Notiz 2026-10-03T09:47:52+02:00

Handoff aktualisiert: Runtime healthy, Memory-Saver-Kombinationsfehler und RAM-PLE-Grenze dokumentiert

## Notiz 2026-10-03T09:53:47+02:00

Systemoptimierungs-Matrix erweitert: Linux-VM, ZFS-ARC, Page-Cache, NVMe, CPU und NUMA als getrennte Testarme

## Notiz 2026-10-03T09:57:49+02:00

Kernel-, Scheduler-, ZFS-ARC-, VM- und I/O-Testarme samt Ableitungsregeln dokumentiert

## Notiz 2026-10-03T10:00:21+02:00

Sweep startet aktives sweet-Profil ohne unnoetigen Neustart erneut

## Notiz 2026-10-03T10:05:00+02:00

Ein 470k-Token-OpenCode-Request hat den laufenden Messblock ungueltig gemacht
und danach einen echten CUDA-OOM ausgeloest: nur 68 MiB frei, 12,35 GiB in
privaten CUDA-Graph-Pools. Die Session wurde beendet und Pennyroyal ueber den
kontrollierten Runtime-Pfad neu gestartet. Dieser Lauf wird verworfen; neue
Benchmarks starten erst nach `healthy` mit leerem KV-/Graph-Zustand. Waerend
des Sweeps keine lokale API-Architekturfragen und keine OpenCode-Sitzungen
gegen dieselbe Runtime senden.

## Notiz 2026-10-03T10:03:59+02:00

470k-Token-Session als Messstoerung und CUDA-OOM mit Graph-Pool-Belegung dokumentiert

## Notiz 2026-10-03T10:22:30+02:00

Performance-Sweep: Profil sweet abgeschlossen

## Notiz 2026-10-03T11:47:51+02:00

Tuning-Guard toleriert API-Aussetzer waehrend Kaltstart; maxkv kann danach sicher angewendet werden

## Notiz 2026-10-03T11:48:00+02:00

Nach der Rueckkehr wurde der Zustand geprueft: Seit dem CUDA-OOM um 10:22
liefen keine weiteren Benchmarks; der Sweep war beendet. Der OOM trat bei einem
Long-Context-Test auf, nachdem die Runtime mit nur etwa 0,1 GiB freiem VRAM und
12,35 GiB privaten CUDA-Graph-Pools gestartet war. Die Auswertung verwirft diesen
Block. Pennyroyal wurde danach erneut ueber `apply-runtime-unit.sh` gestartet.

Das Profil `maxkv` ist nach dem beobachteten OOM vorlaeufig auf 1 Request,
4 Mamba-Slots, Graph-Maximum 1, `mem_fraction=0.975` und KV-Ziel 524.288
gesetzt (acht Slots, weil die Runtime aktuell `mamba_ratio=5` meldet; vier
Slots wuerden selbst bei C1 auf null zugelassene Requests runden). Der vorherige Lauf mit 4 Requests, 16 Slots und Graph-Maximum 4
erreichte zwar `/health`, starb aber bei der ersten kurzen Folgeanfrage: nur
8 MiB frei, 12,35 GiB private CUDA-Graph-Pools, lazy Triton-Kernel benoetigten
weitere 80 MiB. Das ist ein echter VRAM-Reservefehler, kein Long-Context-Test.
Das Profil konnte waehrend des Kaltstarts zunaechst nicht angewendet werden, weil
`apply-tuning.sh` einen temporaeren Curl-Exit 56 unter `set -e -o pipefail`
als Fehler behandelte. Dieser Guard ist in Commit `f948499` repariert. Nach
`healthy` erneut ausfuehren:

```bash
./scripts/apply-tuning.sh --profil maxkv --ohnemessung
```

Danach lokale API nur fuer Architektur-/Planungsfragen nutzen, niemals waehrend
vergleichbarer Benchmarks. Jeder neue Long-Context-Test muss vorab die tatsaechlich
profilierte `sglang:max_total_num_tokens`-Grenze pruefen.

## Notiz 2026-10-03T11:50:07+02:00

Handoff fuer den anderen Agenten aktualisiert: OOM, Sweep-Stopp, maxkv-Guard und naechster Schritt

## Notiz 2026-10-03T11:51:05+02:00

Handoff fuer den anderen Agenten aktualisiert: OOM, Sweep-Stopp, maxkv-Guard und naechster Schritt

## Notiz 2026-10-03T12:35:00+02:00

Der erste `maxkv`-Anlauf hat den neuen NVMe-PLE-Start korrekt bis zum
Gewichteladen gebracht (47,68 GiB Stream, ca. 83,5 GiB VRAM, Ladezeit ca.
19 Minuten), wurde aber vom Warte-Gatter nach 1200 Sekunden beendet. Ursache:
`apply-tuning.sh` setzte `RUNTIME_WAIT_SECONDS=2400` nicht exportiert; das
Kindskript fiel dadurch auf seinen alten Default 1200 zurueck. Der Container
wurde mit Status 137 beendet und der Rueckfall gestartet. `wait-for-runtime.sh`
hat jetzt Default 2400 Sekunden: Warnung nach 30 Minuten. Nach 40 Minuten
bricht sie nur ab, wenn seit zehn Minuten weder Journalfortschritt noch CPU-
oder GPU-Aktivitaet messbar ist; bei Aktivitaet verlaengert sie die Pruefung
in Fuenf-Minuten-Schritten. `apply-tuning.sh` exportiert den Wert. Vor dem
naechsten Profilwechsel zuerst `healthy` abwarten; der Lauf selbst ist kein
Benchmark-Ergebnis.

## Notiz 2026-10-03T12:37:47+02:00

Kaltstart-Gatter repariert: `RUNTIME_WAIT_SECONDS` exportiert und Default auf
2400 Sekunden gesetzt (Warnung nach 1800); maxkv-Lauf wegen altem
1200s-Timeout verworfen.

## Notiz 2026-10-03T12:42:00+02:00

Die NVMe liefert laut Hostmessung bis etwa 3 GB/s; die Ladezeit besteht daher
nicht nur aus sequentiellem Lesen. CPU-seitige Initialisierung, PLE-Streaming,
Hash-/Formatpruefung und Triton/FlashInfer/CUDA-Graph-Kompilierung laufen
teilweise parallel, teilweise serialisiert. Das Rezept setzt derzeit
`OMP_NUM_THREADS=4` und `MKL_NUM_THREADS=4` (konfigurierbar). Ein 8-Thread-Test
ist ein eigener Messarm: Startzeit, GPU-Auslastung und Serving-Durchsatz messen;
mehr Threads koennen den Start verkuerzen, aber waehrend des laufenden Modells
auch CPU-Konkurrenz erzeugen. 3D-V-Cache allein ist fuer diesen NVMe-/GPU-
Transfer kein erwartbarer Haupthebel.

## Notiz 2026-10-03T12:43:47+02:00

Runtime-Wartefenster: Warnung nach 30 Minuten, bei Inaktivitaet Abbruch ab 40 Minuten; Handoff zu Multi-Thread-Starttests ergänzt

## Notiz 2026-10-03T12:50:00+02:00

Wartepruefung folgt jetzt dem Betreiberkriterium Prozessfortschritt statt
starrer Zeit: alle 60 Sekunden werden letzter Journalzeitpunkt, Containerstatus,
Container-CPU, GPU-Auslastung und belegter GPU-Speicher ausgegeben. Der
Containerabbruch wird sofort gemeldet. Ab 40 Minuten fuehrt erkennbare
CPU-/GPU-Aktivitaet oder ein frischer Logeintrag zu weiteren Pruefungen in
Fuenf-Minuten-Schritten; Timeout gibt es erst bei zehn Minuten kompletter
Inaktivitaet. Damit wird ein langsamer, aber weiterarbeitender Modellstart nicht
abgeschnitten. NVMe-I/O wird derzeit noch nicht direkt als eigener Fortschritts-
indikator gemessen.

## Notiz 2026-10-03T13:10:00+02:00

Netzrecherche zu aggressiveren Zielprofilen abgeschlossen. Offizielles
Pennyroyal v2.5.3 nennt auf derselben 96-GiB-RTX-PRO-6000 Flash-Next C=6 und
1.039.040 beobachtete KV-Tokens; Online-FP8 spart etwa 3,86 GiB VRAM und hebt
C1 offiziell von 161,47 auf 207,12 Token/s. Community-Profile melden C4 mit
ca. 572K KV und C8 mit 758 Token/s aggregiert (dafuer etwa 6 Mamba-Slots je
Request sowie teilweise relaxte MTP-Annahme), oder C8 mit 282.432 KV bei
`mem_fraction=0.975` und 632,4 Token/s. Diese Werte sind dokumentierte Ziele,
nicht direkt uebertragbare Garantien fuer NVMe-PLE.

Der laufende Rettungslauf bleibt unveraendert. Nach Stabilitaetsnachweis wird
die Messleiter C1 -> Online-FP8 -> C4 -> C6 -> C8 gefahren; pro Stufe kurze,
mittlere und lange Kontexte, Wiederholungen und Soak-Test. Keine weitere
Parallelitaet aus den externen Zahlen blind aktivieren.

## Notiz 2026-10-03T12:46:54+02:00

Startup-Wartepruefung auf echte Aktivitaet umgestellt: Container, Journal, CPU, GPU und VRAM; bei Fortschritt ueber 40 Minuten hinaus warten

## Notiz 2026-10-03T12:47:30+02:00

Startup-Wartepruefung auf echte Aktivitaet umgestellt: Container, Journal, CPU, GPU und VRAM; bei Fortschritt ueber 40 Minuten hinaus warten

## Notiz 2026-10-03T13:05:26+02:00

CUDA-OOM nach gesundem Start dokumentiert: 12.35 GiB Graph-Pools und lazy Triton-Kernel; maxkv vorlaeufig auf Single-Request mit Graph 1 und 0.975 Reserve gesetzt

## Notiz 2026-10-03T13:17:54+02:00

Pennyroyal-Zielprofile recherchiert und dokumentiert: offizielles C6/1.039M KV, Online-FP8 VRAM-Gewinn, Community C4/C8; Messleiter nach stabilem C1

## Notiz 2026-10-03T13:29:45+02:00

Sicherheitsprofilstart diagnostiziert: mamba_ratio=5, vier Slots ergaben max_num_reqs=0; Guard auf 5 und C1 maxkv auf 8 Slots korrigiert

## Notiz 2026-10-03T13:30:27+02:00

Sicherheitsprofilstart diagnostiziert: mamba_ratio=5, vier Slots ergaben max_num_reqs=0; Guard auf 5 und C1 maxkv auf 8 Slots korrigiert

## Notiz 2026-10-03T14:14:50+02:00

C6-Produktionsprofil vorbereitet: Online-FP8, 6 Requests, 36 Mamba-Slots, 1M KV, HiCache 16, NVMe-PLE; mem_fraction-Override wird fuer offiziellen Default entfernt

## Notiz 2026-10-03T14:20:00+02:00

C6-Start auf Nutzerwunsch vor Ready abgebrochen, damit ein alternativer
Agentenvorschlag geprueft werden kann. Die generierte Unit enthielt bereits
Online-FP8, 6 Requests, 36 Mamba-Slots, Graph-Maximum 6 und 1M KV; es gab noch
keine Benchmarkdaten. Der Stop lief in SIGKILL/Status 137 aus, nachdem der
Kaltstart nur wenige Minuten alt war; daraus darf kein OOM-Urteil ueber C6
abgeleitet werden. Aktueller Pod ist gestoppt. Vor dem naechsten Start neuen
Vorschlag gegen diese Unit und das bestehende PLE-/NIXL-Layout vergleichen.

## Notiz 2026-10-03T14:21:08+02:00

C6-Start auf Nutzerwunsch vor Ready gestoppt; generierte Unit mit Online-FP8/6/36/1M dokumentiert, keine Benchmarkdaten

## Notiz 2026-10-03T14:30:00+02:00

Separater Branch `turbo-c6-production` angelegt. Er verwendet Turbo r24 als
Compute-Basis, C6/27 Mamba-Slots, Online-MXFP8, FP8-KV, NEXTN/MTP und 8 GiB
HiCache. NVMe-PLE wird aus dem vorhandenen Overlay per Datei-Backend gelesen;
Pennyroyal bleibt unveraendert als Fallback auf Port 8001. Imagebau und Smoke-
Start erfolgen mit `make turbo-c6-install` und `make turbo-c6`; noch keine
Live-Anwendung oder Smoke-Daten in diesem Stand.

## Notiz 2026-10-03T14:42:05+02:00

Separater Turbo-C6-Branch vorbereitet: r24, eigenes Image/Quadlet, C6 mit 27 Mamba-Slots und NVMe-PLE; Pennyroyal bleibt Fallback


## Notiz 2026-10-03T15:00:00+02:00

Turbo-C6-Image r24 wurde separat gebaut und auf Port 8002 gestartet. Die
Konfiguration wurde bis zur Modellinitialisierung korrekt erkannt (C6, 27
Mamba, Online-MXFP8, FP8-KV, NEXTN/MTP, 8 GiB HiCache). Der Smoke-Start scheitert
gezielt an der Turbo-Datei-PLE-Pruefung: RTX PRO 6000 ist kein Unified-Memory-
Geraet, daher verweigert r24 `--ple-offload-backend file`. Dienst bleibt aus;
Pennyroyal bleibt Fallback. Kein OOM. Ein Port des Pennyroyal-SSD-Stream-Hooks
gegen die Turbo-Revision ist offen und darf nicht durch Hash-Pruefung-Bypass
unqualifiziert aktiviert werden.

## Notiz 2026-10-03T15:03:02+02:00

Turbo r24 separat gebaut; Smoke zeigte harte Inkompatibilitaet von Datei-PLE auf RTX PRO 6000; Dienst gestoppt, Pennyroyal Fallback

## Notiz 2026-10-03T17:30:00+02:00

PR #36567 gegen Turbo r24 geprueft. Das Overlay uebernimmt nur die Storage-/Qwen4-
NVMe-PLE-Commits `04648a7015` und `9f101e39ff`; der SM121-QSA-Commit bleibt weg.
Turbo bleibt Compute-Basis, Pennyroyal unveraendert Fallback. Das PR-Modul nutzt
den Original-Snapshot `/models/Qwen3.8-Flash-Next-NVFP4` (128 FP8-PLE-Shards),
nicht das alte Penny-`layer-0.bin`-Overlay. Neues Image-Tag ist
`localhost/sglang-qwen38fn-sm120-turbo:r24-pr36567`, Dienst bleibt Port 8002.
Der Quadlet nutzt ein begrenztes io_uring-Seccomp-Profil und setzt C6/27/8 GiB/
1M KV sowie Online-MXFP8, FP8-KV und NEXTN. Image-/Smoke-Bau steht noch aus;
Live-GPU-Smoke bleibt wegen des aktuellen NVIDIA-Hostzustands blockiert.

## Notiz 2026-10-03T17:40:37+02:00

PR36567 NVMe-PLE-Overlay gegen Turbo r24 integriert; SM121 bewusst ausgelassen; Smoke folgt nach Imagebau

## Notiz 2026-10-03T17:50:16+02:00

PR36567 Overlay gebaut und validiert; Manifest 128 Shards/51.2GB; Rust io_uring cargo check ok; Live GPU-Smoke wegen nvidia-smi No devices found ausstehend

## Notiz 2026-10-03T17:54:51+02:00

PR36567 io_uring Row-Smoke erfolgreich (3 Zeilen); GPU-Smoke bewusst ausgesetzt wegen nvidia-smi No devices found

## Notiz 2026-10-03T17:56:30+02:00

Konfliktaufloesung PR36567 gegen vorhandene Turbo-PLE/NVFP4-Hooks explizit dokumentiert

## Notiz 2026-10-03T18:10:00+02:00 – NVIDIA/PCIe-Recovery offen

Die RTX PRO 6000 Blackwell ist im PCIe-Baum weiterhin sichtbar (`0000:22:00.0`,
GB202GL), aber der NVIDIA-Treiber hat sie nach einem GPU-Hänger vom Bus verloren:

```text
NVRM: GPU 0000:22:00.0: GPU has fallen off the bus
pciehp: Slot(0): Link Down
nvidia-modeset: Error while waiting for GPU progress
rm_power_source_change_event: Failed ... status=0xf
```

`nvidia-smi -L` meldet aktuell `No devices found`; bei `lspci -nnk` steht kein
`Kernel driver in use`. Zwei alte `nvtop`-Prozesse wurden beendet, sie waren
nicht die Ursache. IRQ 124 ist der PCIe-Hotplug-Thread (`irq/124-pciehp`) und
kein LLM-Prozess.

CDI (Container Device Interface) ist die Podman-Zuordnungsdatei
`/etc/cdi/nvidia.yaml`. Sie übersetzt `nvidia.com/gpu=all` in konkrete NVIDIA-
und DRM-Geräte. Die vorhandene Datei verweist noch auf `card0`/`renderD129`,
die derzeit nicht existieren; nach erfolgreicher Treiberinitialisierung muss
sie neu erzeugt werden:

```bash
sudo reboot
nvidia-smi -L
sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
nvidia-ctk cdi list
```

Bis dahin keinen Turbo- oder Penny-Neustart erzwingen. Der Produktionszweig
`turbo-c6-production` enthält das PR36567-Overlay (`r24-pr36567`) und bleibt
sauber gepusht; Pennyroyal bleibt Fallback. Nach der GPU-Recovery zuerst CDI und
`podman run --rm --device nvidia.com/gpu=all ... nvidia-smi` prüfen, dann erst die
neue Port-8002-Unit anwenden.

## Notiz 2026-10-03T18:13:03+02:00

GPU/PCIe-Ausfall und CDI-Recovery fuer den naechsten Agenten dokumentiert

## Notiz 2026-10-03T19:16:00+02:00 – Turbo-SSD-Stream laeuft

Nach dem Neustart wurde die RTX PRO 6000 erkannt, CDI neu erzeugt und der
Podman-GPU-Smoke bestanden. Der Turbo-r24-PR36567-Dienst laeuft jetzt gesund
auf Port 8002 und ist alleiniger GPU-Nutzer; Pennyroyal ist als Fallback
gestoppt. Der Startlog bestaetigt den NVMe-PLE-Reader mit 47,68 GiB in 10
Dateien und 320.001.536 Zeilen. `/health` liefert HTTP 200, ein kurzer
Chat-Request war erfolgreich.

Fuer den isolierten Dienst wurde die `io-uring`-Rust-Extension einmalig mit
Host-Netz gebaut und im persistenten Cache abgelegt. `RUSTUP_TOOLCHAIN=stable`
und `RUSTUP_OFFLINE=1` verhindern erneute Netz- oder Toolchain-Abhaengigkeit.
CUDA-Graphen sind fuer diesen SSD-Pfad deaktiviert, da Graph-Capture den
CPU-seitigen NVMe-Zeilenabruf nicht unterstuetzt. Der naechste sinnvolle Schritt
ist ein Benchmark gegen Pennyroyal nach kontrolliertem Umschalten; dafuer muss
Turbo zuerst gestoppt und Pennyroyal exklusiv gestartet werden.

## Notiz 2026-10-03T18:23:17+02:00

GPU nach Neustart wieder da, CDI neu erzeugt und Podman-GPU-Smoke bestanden

## Notiz 2026-10-03T18:28:09+02:00

GPU- und natives PLE-Volume nach Neustart geprüft; Turbo-Smoke vorbereitet

## Notiz 2026-10-03T18:35:00+02:00

Turbo-Startfehler behoben: Rust-Cargo wird im stabilen Offline-Toolchain des Images ausgefuehrt

## Notiz 2026-10-03T18:38:13+02:00

Turbo-Test isoliert: paralleler Pennyroyal-GPU-Besitz als Ursache des zweiten Starts dokumentiert

## Notiz 2026-10-03T18:53:08+02:00

NVMe-PLE-Overlay bis CUDA-Graph-Warmup validiert; TP1-API-Vertragsmethode ergaenzt

## Notiz 2026-10-03T19:04:30+02:00

Turbo-NVMe-Reader erreicht CUDA-Graph-Capture; SSD-Pfad deaktiviert Graphen gezielt fuer stabile TP1-Ausfuehrung

## Notiz 2026-10-03T19:17:24+02:00

Turbo-SSD-Stream nach GPU-Recovery gesund; Doku, Rust-Cache und exklusiver GPU-Betrieb gesichert

## Notiz 2026-10-03T19:39:57+02:00

Gateway fuer Turbo umgestellt, damit OpenCode nicht mehr auf den gestoppten Penny-Port zeigt

## Notiz 2026-10-03T19:43:02+02:00

OpenCode auf LiteLLM 4000 mit aktuellem Turbo-Modell konfiguriert; vorhandene Datei gesichert

## Notiz 2026-10-03T19:47:22+02:00

Zu niedriger Turbo-Durchsatz diagnostiziert: CUDA-Graphen wegen NVMe-Capture-Transfer aus; Capture-Stub im Reader ergaenzt

## Notiz 2026-10-03T19:52:28+02:00

Turbo-Unit vor kontrolliertem Neustart gesichert

## Notiz 2026-10-03T20:04:06+02:00

Turbo nach Graph-Capture-Fehler vorlaeufig auf stabile PLE-Ausfuehrung gestellt

## Notiz 2026-10-03T20:16:54+02:00

Turbo stabil mit SSD-PLE-Fallback und Benchmark 64.7 tok/s

## Notiz 2026-10-03T20:30:35+02:00

PLE auf mmap/Page-Cache und expliziten CUDA-Capture-Guard umgestellt

## Notiz 2026-10-03T20:40:39+02:00

CUDA-Capture-Guard auf native und breakable graph detection erweitert

## Notiz 2026-10-03T20:54:45+02:00

Turbo nach wiederholtem Capture-Fehler stabilisiert und Unit auf mmap korrigiert

## 7. Turbo/PLE-Varianten (Stand 2026-10-03, diese Sitzung)

Ursache des CUDA-Graph-Capture-Absturzes und der zu geringen Schreibrate ist
geklaert und dokumentiert (Log- und Codebelege in den Doku-Seiten):

* Capture-Abbruch: `qwen4_exp.py:1336` joined den Fremdstream
  `_prefetch_stream` unbedingt in das native Capture, waehrend dort
  Warmlauf-Kopien als nicht erfasste Arbeit anstanden
  (`cudaErrorStreamCaptureIsolation`, Log 20:38/20:50).
* Guard-Defekt: `_capture_active()` pruefte `is_in_breakable_cuda_graph()`,
  das in Capture *und* Replay gilt - im Breakable-Replay waere der echte
  PLE-Lauf zum Null-Stub erstarrt. Mit dem `full`-Backend enthaelt das Graph
  nur den Null-Stub; korrekte PLE-Graphen liefert nur
  `--cuda-graph-backend-decode=breakable`.
* Langsamkeit (31 tok/s C1): `mean_read_ms=199,9` pro Gather (~720 Zeilen):
  QD1-Sequenzlesen, ein IO-Worker, blockierendes `future.result()`,
  Einzel-Staging-Puffer mit Event-Stall; io_uring-Seitencache Default 0.

Vorbereitete, **getrennt startbare** Varianten (je eigener Branch, Worktree,
Bild-Tag, Port; keine davon getestet, kein Bild gebaut, nichts gestartet):

| Variante | Branch | Worktree | Port | Kern |
|---|---|---|---|---|
| A | `turbo-upstream-ple-graph` | `~/work/llm-infra-setup-turbo-upstream` | 8003 | graph-sichere Guards + breakable Decode-Graphen |
| B | `variant-b-mmap-pagecache` | `~/work/llm-infra-setup-variant-b` | 8004 | wie A + mmap/Page-Cache + begrenzter LRU + Sync-Modus |
| C | `pennyroyal-plugin-variant` | `~/work/llm-infra-setup-pennyroyal` | 8001 | offizielles Pennyroyal-`ssd_stream`-Plugin (Bild), nur Konfiguration |
| D | `variant-d-staging-double-buffer` | `~/work/llm-infra-setup-variant-d` | 8005 | wie B + Double-Buffer-Pinned-Staging |

Empfehlung: Rangfolge ohne Benchmark unbekannt; **C** strukturell
vielversprechend, **B** möglicher Cache-Gewinn, **D** möglicher
Staging-Gewinn, **A** Capture-Referenz. Der complete Testauftrag (Build, Start, C1/C6-Messung mit
TTFT/steady/aggregat, Rueckbau, Checkpoints) liegt in
`docs/variant-test-prompt.md`; die Vergleichstabelle in
`docs/variant-comparison.md` (je Variantenzweig committet). Der
Produktionsdienst `sglang-turbo-c6` (Port 8002, `--disable-cuda-graph`,
PLE mmap) laeuft unveraendert weiter; Pennyroyal bleibt Fallback.


## Notiz 2026-10-03T23:57:28+02:00

Doku: Rangfolge ohne Benchmark unbekannt, ple-preload.sh qualifiziert

## Notiz 2026-10-04T00:02:10+02:00

HANDOFF.md: Rangfolge ohne Benchmark unbekannt; A-D sachlich eingeordnet

## Notiz 2026-10-04T00:04:16+02:00

Vorbereitung der sequenziellen Variantenprüfung A-B-D-C
