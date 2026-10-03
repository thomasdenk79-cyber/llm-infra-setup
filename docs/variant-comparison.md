# Turbo/PLE-Varianten im Vergleich

Ziel: Ursache der niedrigen Turbo-Leistung und des CUDA-Graph-Capture-Absturzes
beheben, ohne das Turbo-Rezept unnötig zu verändern. Jede Variante läuft in
eigenem Branch, eigenem Worktree, eigenem Image-Tag, eigenem Container und
eigenem Port; Produktionsdienst (`sglang-turbo-c6`, Port 8002) und Pennyroyal
bleiben unverändert. GPU-Exklusivität beachten: immer nur ein Laufzeitdienst
gleich starten.

## Diagnose (gilt für alle Varianten)

* Capture-Absturz: `qwen4_exp.py:1336` joined den Fremdstream
  `_prefetch_stream` unbedingt in das native Graph-Capture, während dort
  Warmlauf-Kopien als nicht erfasste Arbeit anstanden
  (`cudaErrorStreamCaptureIsolation`, Log 2026-10-03 20:38/20:50).
* Guard-Defekt: `_capture_active()` (qwen4_ple_nvme.py) prüfte
  `is_in_breakable_cuda_graph()`, das in Capture *und* Replay gilt -> im
  Breakable-Replay wäre der echte PLE-Lauf zum Null-Stub erstarrt.
* Mit dem `full`-Decode-Backend enthält das Graph nur den Null-Stub; korrekte
  PLE-Werte mit Graphen liefert nur das `breakable`-Backend (echte Koerper
  als Break-Funktionen im Replay).
* Langsamkeit (ohne Graphen, 31 tok/s C1): Log `Qwen4 PLE NVMe: calls=1000
  rows=720240 mean_read_ms=199.935` -> ~200 ms SSD-Wartzeit pro Gather bei
  ~720 Zeilen, sequenziell (QD1), ein IO-Worker, blockierendes
  `future.result()` im Modell-Thread, dazu Einzel-Staging-Puffer mit
  Ereignis-Synchronisation vor jeder `memmove`.

## Tabelle

| Variante | Basis | PLE-Pfad | Cachemodell | CUDA-Graph-Strategie | erwarteter Effekt | Risiko |
|---|---|---|---|---|---|---|
| A `turbo-upstream-ple-graph` | Turbo r24 + PR36567-Overlay, Rezept unverändert | io_uring (O_DIRECT), Upstream-Reader | keiner (Upstream-Default CACHE_PAGES=0) | Graphen an, Decode `breakable`; nativer Capture nur mit Stub, Join bedingt | Capture stabil; Decode nah an 200 tok/s C1, io_uring-I/O bleibt ~200 ms/Schritt, ueberlappend | Breakable mit Mamba/NEXTN live ungetestet; Memory-Saver-Kollision (Schalter) |
| B `variant-b-mmap-pagecache` | A | mmap/Page-Cache (+ Vorladen), optional synchroner Modus | begrenzter LRU-Zeilen-Cache, Groesse per Unit (MiB), Default 0 = aus | wie A (breakable); kein asynchrones Future noetig fuer Korrektheit | Cache-Treffer statt SSD; Anlauf schnell nach `ple-preload.sh`; io_uring-Seccomp entfaellt | Cache-Groesse gegen ARC/HiCache abzuessen; QD1 bleibt, Trefferquote von Tokenverteilung abhaengig |
| C `pennyroyal-plugin-variant` | Pennyroyal v2.5.3 (Fallback-Pfad) | eingebautes SSD-Stream-Plugin (PENNY_PLE_BACKEND=nvme) | HiCache hostseitig (16 GiB), Bild-eigener Reader | Pennyroyal-Standard (Decode-Graphen wie Produktionsprofil) | offiziell unterstuetzter SSD-Pfad ohne Turbo-Overlay; Fallbackfaehigkeit bleibt | Plugin-Zutritt (.ple-nvme, check_ple_nvme.py) muss im Bild vorhanden sein; nicht gegen Turbo gemessen |
| D `variant-d-staging-double-buffer` | B | wie B | wie B | wie A/B | zus. Wegfall der Staging-Stall: Double-Buffer-Pinned-Staging ueberlappt memmove mit H2D; stabiler Stub-Ausgabepuffer bewusst verworfen (Graph-Pool-Risiko) | groesster Codeumfang; zwei Slots verdoppeln Staging-Fussabdruck |

## Status

| Variante | Stand | Getestet? |
|---|---|---|
| A | vorbereitet, Commits im Branch | **nein - kein Live-Betrieb, kein Benchmark durchgefuehrt** |
| B | vorbereitet | **nein** |
| C | vorbereitet (Bestandsbranch, vervollstaendigt) | **nein** |
| D | vorbereitet | **nein** |

Empfohlene Reihenfolge fuer spaetere Live-Tests: A zuerst (kleinster Eingriff,
bewiesener BCG-Entwurfs Pfad), dann B (falls io_uring-Latenz dominiert), D
(falls Staging-Stall messbar bleibt), C als Vergleichsbasis der offiziellen
PLE-Schiene.

## Betrieb: Start/Stopp je Variante

Alle Vergleichsdienste laufen exclusiveGPU (vorher `sglang-turbo-c6.service`
stoppen, danach zurueckstarten). Units werden erst durch das jeweilige
Install-Skript erzeugt und committet nicht live geaendert.

| Variante | Worktree | Installation | Start | Stopp |
|---|---|---|---|---|
| A | ~/work/llm-infra-setup-turbo-upstream | `./scripts/52-install-sglang-turbo-upstream-ple.sh` | `systemctl --user start sglang-turbo-upstream-ple.service` | `systemctl --user stop sglang-turbo-upstream-ple.service` |
| B | ~/work/llm-infra-setup-variant-b | `./scripts/53-install-sglang-turbo-variant-b.sh` | `systemctl --user start sglang-turbo-variant-b.service` | `systemctl --user stop sglang-turbo-variant-b.service` |
| C | ~/work/llm-infra-setup-pennyroyal | `./scripts/50-install-pennyroyal.sh` (PENNY_PLE_BACKEND=nvme) | `./scripts/apply-runtime-unit.sh --restart-only` (Pennyroyal-Pfad) | Pennyroyal-Unit stoppen, Turbo zurueck |
| D | ~/work/llm-infra-setup-variant-d | `./scripts/54-install-sglang-turbo-variant-d.sh` | `systemctl --user start sglang-turbo-variant-d.service` | `systemctl --user stop sglang-turbo-variant-d.service` |

Nach jedem Test: `./scripts/session-checkpoint.sh "Variante X Messung"` im
betreffenden Worktree, Messungen bleiben in `state/benchmarks/` und werden
nach `docs/` gesichert.

## Messdefinition (einheitlich)

`scripts/benchmark.sh` mit `PENNYROYAL_PORT` auf den Variantendienst:
TTFT (Median/p95), `steady_tokens_per_second` pro Anfrage (Median/p95) und
`aggregate_tokens_per_second` ueber den Wanduhrzeitraum - jeweils getrennt
ausweisen fuer C1 und C6.
