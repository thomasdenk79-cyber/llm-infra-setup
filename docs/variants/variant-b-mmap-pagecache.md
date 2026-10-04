# Variante B: Turbo mit mmap-/Page-Cache-PLE

* Branch: `variant-b-mmap-pagecache` (aufgetropft auf `turbo-upstream-ple-graph`)
* Worktree: `~/work/llm-infra-setup-variant-b`
* Ausgangscommit: Variante-A-Zweig (Basis `1273262`)
* Bild-Tag: `localhost/sglang-qwen38fn-sm120-turbo:r24-pr36567-variant-b`
* Port: 8004 (127.0.0.1), Container `sglang-turbo-variant-b`

## Idee

Der io_uring-/O_DIRECT-Pfad umgeht den Page-Cache und las bei ~200 ms pro
Gather (Log: `mean_read_ms=199.935` bei ~720 Zeilen, QD1). Variante B liest
ueber mmap durch den Linux-Seitenspeicher (bzw. ZFS-ARC dahinter) und legt
zusaetzlich einen **begrenzten In-Prozess-Zeilen-LRU** an, damit heisse
N-Gramm-Zeilen ohne Systemaufruf fertig werden. Damit entfallen O_DIRECT,
io_uring und dessen Seccomp-Abhaengigkeit im Alltag.

Zusammen mit Variante A bleibt der graph-sichere Pfad bestehen: waehrend des
Captures laufen weder mmap-Zugriff noch Futures noch Fremdstream-Kopien
(Guards in `start_gather`/`finish_gather` und bedingter Join in qwen4_exp).
Zusaetzlich kann der Reader vollstaendig synchron gestellt werden
(`SGLANG_QWEN4_PLE_NVME_PREFETCH=sync`): dann gibt es waehrend der Inferenz
gar keinen IO-Worker-Thread und kein blockierendes `future.result()` - der
Preis ist fehlende Ueberlappung, der Gewinn ist ein Determinismuspfad fuer
Vergleichsmessungen.

## Geaenderte Dateien (gegenueber A)

* `config/turbo/pr36567-overlay/python/sglang/srt/environ.py`
  - `SGLANG_QWEN4_PLE_NVME_MMAP_CACHE_MB` (Int, Default 0 = aus)
  - `SGLANG_QWEN4_PLE_NVME_PREFETCH` (async|sync, Default async)
* `config/turbo/pr36567-overlay/python/sglang/srt/models/qwen4_ple_nvme.py`
  - `MMapRowReader`: LRU nach (Datei, Offset), Zeilenzahl aus dem MiB-Budget
    (`MB*2^20 / row_bytes`), kein hartkodierter Speicherwert, 0 = aus
  - `start_gather`: Sync-Modus fuellt das Future inline
* `scripts/53-install-sglang-turbo-variant-b.sh` (neu): eigenes Bild, Unit
  Port 8004, setzt `BACKEND=mmap`, `MMAP_CACHE_MB` (Unit-Default 512),
  `PREFETCH` (Unit-Default async)
* `docs/variants/variant-b-mmap-pagecache.md`, `docs/variant-comparison.md`,
  `mkdocs.yml`

## Cachemodell

| Ebene | Mechanismus | Groeße |
|---|---|---|
| In-Prozess-LRU | `MMapRowReader._cache`, LRU u.ber (Datei, Offset) | `SGLANG_QWEN4_PLE_NVME_MMAP_CACHE_MB` (Unit: 512 MiB) |
| Page-Cache/ARC | nativ ueber mmap, Vorwarmen mit `./scripts/ple-preload.sh` | durch Kernel/ARC-Deckel begrenzt |

Der LRU liegt im Prozess-Heap (normale Bytes), nicht pinned; er wird bei
`close()` geleert. Die Zeilenlaenge kommt aus dem Manifest (`row_bytes`), ein
Einstellfehler erhoehet nur den Cache-Sockel, nicht die Tabelle.

## CUDA-Operationen im Capture

identisch zu Variante A (siehe dort); im `sync`-Modus zusaetzlich: auch
ausserhalb des Captures keine IO-Threads, keine Futures - die einzigen
CUDA-Aktivitaeten aus dem Reader sind dann die H2D-Kopie auf dem
Prefetch-Strom und ihr Event (ausserhalb jedes Captures).

## Start (spaeter, manuell)

```bash
cd ~/work/llm-infra-setup-variant-b
make turbo-c6-install
./scripts/53-install-sglang-turbo-variant-b.sh
./scripts/ple-preload.sh            # Tabelle in den Seitenspeicher
systemctl --user daemon-reload
systemctl --user stop sglang-turbo-c6.service
systemctl --user start sglang-turbo-variant-b.service
curl -fsS http://127.0.0.1:8004/health
```

## Stop/Rollback

```bash
systemctl --user stop sglang-turbo-variant-b.service
systemctl --user start sglang-turbo-c6.service
```

## Messen

C1/C6 getrennt gegen Port 8004 mit `PENNYROYAL_PORT=8004
BENCHMARK_MODEL=Qwen3.8-Flash-Next ./scripts/benchmark.sh quick <1|6>`;
Log-Kennzahl `mean_read_ms` vor/nach Vorladen notieren.

## Healing 2026-10-04

Der Start wurde erst nach erfolgreicher Runtime-Initialisierung beendet. Das
Protokoll zeigt erfolgreiche CUDA-Graph-Captures fuer Target-Verify, Draft
Decode und Draft Extend sowie den mmap-PLE mit 47,68 GiB/320.001.536 Zeilen.
Der anschliessende `sm120_turbo_structured_output`-Warmup lief durch EAGLE bis
XGrammar; dort trafen 1 Logits-Zeile auf eine Grammar-Bitmaske mit 4 Zeilen
(`batch size mismatch: logits 1 vs bitmask 4`). Das ist die belegte
Abbruchursache, nicht CUDA-Graph-Capture oder PLE-Leser.

Der erste Healing-Patch setzte fuer Variante B zwar `TURBO_WARMUPS=none`,
liess aber im gemeinsamen Launcher das feste Argument
`--warmups sm120_turbo_structured_output` stehen. Dadurch lief der fehlerhafte
Warmup trotz der Umgebungsvariable weiter. Der minimale Reparaturpatch entfernt
nur dieses feste Argument; der Launcher fuegt den Warmup jetzt ausschliesslich
bei `TURBO_WARMUPS != none` hinzu. Der Capture der Decode- und Verify-Graphen
bleibt aktiv und der mmap-/LRU-PLE-Pfad unveraendert. Produktions-Units werden
nicht geaendert.

Restrisiko: Ohne den Request-Warmup entfaellt dessen Kernel-/Pfad-Aufwaermung;
die expliziten CUDA-Graph-Captures laufen beim Start weiter, aber ein spaeterer
Live-Start muss Server-Health und echte strukturierte Anfragen bestaetigen. Der
Patch umgeht den fehlerhaften Warmup und behebt nicht die EAGLE/XGrammar-
Batchform-Inkonsistenz. Es wurden keine Pods gestartet und kein Benchmark
ausgefuehrt.

## Forschungsnotiz

Siehe [research-loop.md](../research-loop.md) fuer Primaerquelle, Datum und
Entscheidung. Ein Folge-Branch ist derzeit nicht gerechtfertigt: Ein
verifizierter Upstream-Fix fuer genau diesen EAGLE/XGrammar-Batchfehler wurde
nicht gefunden.

## Risiken / offene Punkte

* Cache-Hits haengen an der Token-/N-Gramm-Verteilung der Last; die
  Benchmark-Prompts treffen moeglicherweise unguenstige Zeilen.
* 512 MiB LRU + HiCache 8 GiB + ARC konkurrieren um RAM - vor dem Start
  `free -h` pruefen, ggf. MMAP_CACHE_MB senken.
* Sync-Modus kann die Vorlaufzeit pro Schritt erhohen (keine Ueberlappung);
* er dient als Nachweispfad, nicht als Zielkonfiguration.
* Kein Live-Test, kein Benchmark durchgefuehrt; der Patch ist statisch geprueft.
