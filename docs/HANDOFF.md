Zuletzt gesichert: 2026-10-03T11:47:51+02:00 durch `scripts/session-checkpoint.sh`

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
./scripts/apply-tuning.sh --profil maxkv                # 2 Anfragen, mehr KV-Speicher
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
