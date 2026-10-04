# Variante A: Upstream-Turbo mit graph-sicherem PLE-Pfad

* Branch: `turbo-upstream-ple-graph`
* Worktree: `~/work/llm-infra-setup-turbo-upstream`
* Ausgangscommit: `1273262` (turbo-c6-production, Stand 2026-10-03T20:54)
* Bild-Tag: `localhost/sglang-qwen38fn-sm120-turbo:r24-pr36567-variant-a`
* Port: 8003 (127.0.0.1), Container `sglang-turbo-upstream-ple`

## Geaenderte Dateien

* `config/turbo/pr36567-overlay/python/sglang/srt/models/qwen4_ple_nvme.py`
  - `_capture_active()` -> `_native_capture_active()`: nur noch
    `torch.cuda.is_current_stream_capturing()`; Breakable-Replay laeuft damit
    den echten Koerper statt des Null-Stubs.
  - `_note_capture_stub()`: einmalige Warnung, wenn ein volles Graph den
    Null-Stub aufzeichnet (voller Backend-Modus ist fuer NVMe-PLE falsch).
* `config/turbo/pr36567-overlay/python/sglang/srt/models/qwen4_exp.py`
  - Join in `_consume_prefetched_embeddings` nur noch bei UVA-Pfad oder
    ausserhalb nativen Captures (fixed die Capture-Isolation-Panik).
* `config/turbo/serve-qwen38-flash-next-c6-upstream-ple.sh`
  - Graph-Schalter: `TURBO_CUDA_GRAPH=on|off` (sicherer Standard: `off`),
    `TURBO_CUDA_GRAPH_BACKEND_DECODE=breakable|full`,
    `TURBO_SLEEP_ON_IDLE=on|off`.
* `scripts/52-install-sglang-turbo-upstream-ple.sh`
  - baut das Overlay-Bild aus dem Branch (eigenes Tag), prueft r24-Revision.
* `docs/turbo-upstream-ple.md`, `docs/variant-comparison.md` (neu)

## Idee und Fehlerbehebung

Das Turbo-Rezept und der SSD-PLE-Reader bleiben unveraendert. Der sichere
Standard laeuft ohne CUDA-Graph-Capture, weil der r24-Breakable-Backend beim
Capture ein nicht unterstuetztes `LogitsProcessorOutput` liefert. Dadurch wird
weder ein Dienstabbruch noch ein Replay mit falschen (Null-)PLE-Zeilen
zugelassen. Die beiden Overlay-Patches beheben weiterhin die urspruenglichen
Capture-Fehler, falls der Graph-Pfad spaeter gezielt getestet wird:

1. Der unbedingte `wait_stream(_prefetch_stream)`-Join wartete im nativen
   Capture auf einem nicht erfassten Fremdstream
   (`cudaErrorStreamCaptureIsolation`, qwen4_exp.py:1336).
2. Der Guard auf `is_in_breakable_cuda_graph()` haette im Breakable-Replay
   die echten PLE-Zeilen durch Nullen ersetzt (lauterer Datenfehler).

## CUDA-Operationen im Capture: erlaubt vs. ausgeschlossen

* Erlaubt: alle Kernel des Forward auf dem Capture-Strom, Zuweisungen aus dem
  Graph-Speicherpool, Null-Stub (`zero_()`) des PLE, UVA-Gather auf einem per
  `wait_stream` angezweigten Begleitstrom.
* Ausgeschlossen (durch Guards erzwungen): mmap-/io_uring-Lesen,
  `ThreadPoolExecutor.submit`, `Future.result()`, H2D-Kopien,
  Event-Record/Synchronize auf Fremdstreams, `wait_stream` auf einen nicht
  angezweigten Strom.
* Im Breakable-Replay (ausserhalb aller Capture) sind CPU-/SSD-Arbeit und
  Fremdstreams ausdruecklich vorgesehen.

## Start (spaeter, manuell)

```bash
cd ~/work/llm-infra-setup-turbo-upstream
make turbo-c6-install
./scripts/52-install-sglang-turbo-upstream-ple.sh
systemctl --user daemon-reload
systemctl --user stop sglang-turbo-c6.service          # GPU exclusiv
systemctl --user start sglang-turbo-upstream-ple.service
curl -fsS http://127.0.0.1:8003/health
```

## Stop/Rollback

```bash
systemctl --user stop sglang-turbo-upstream-ple.service
systemctl --user start sglang-turbo-c6.service
```

## Heilung des Laufs 2026-10-04

**Ursache:** Der Evidenzlauf zeigt keinen Runtime- oder CUDA-Capture-Fehler.
Die A-Unit meldete nach dem langen Modellstart `Qwen4 PLE NVMe table: 47.68 GiB
across 10 files`, danach `cuda graph: False` und `/health 200`. Beendet wurde der
Lauf erst nach `benchmark_failed`; der externe Matrix-Restore meldete zusaetzlich
einen Syntaxfehler in `run-ple-variant-matrix.sh` (Zeilen 161/162). Die
Import-Warnungen fuer Sarashina2 sind fuer dieses Textmodell nicht fatal.

**Patch:** Der Generator und die committete A-Quadlet setzen nun explizit
`TURBO_CUDA_GRAPH=off`, `TURBO_CUDA_GRAPH_BACKEND_DECODE=breakable` und
`TURBO_SLEEP_ON_IDLE=on`. Damit kann keine geerbte Systemd-Umgebung versehentlich
den Full-Graph-Pfad aktivieren, der bei NVMe-PLE den nativen Null-Stub aufzeichnen
und beim Replay falsche PLE-Zeilen liefern wuerde. Der SSD-Pfad (`io_uring`) und
alle Capture-Isolations-Guards bleiben unveraendert.

**Restrisiko:** A laeuft damit korrekt eager und ohne CUDA-Graph-Beschleunigung;
der r24-Breakable-Pfad bleibt fuer einen spaeteren, separat freigegebenen Test
vorbehalten.

**Nachprüfung 2026-10-04T05:00:** Die Overlay-Patches (Capture-Isolation,
Breakable-Replay-Guard) sind statisch geprueft (`py_compile`) und in allen drei
Betriebsarten korrekt verzahnt: Eager fuehrt den echten SSD-Pfad, native
Capture zeichnet nur den Null-Stub, Breakable-Replay laeuft den echten Koerper
ausserhalb des Captures. Die A-Unit enthielt im Evidenzlauf keinen CUDA- oder
PLE-Fehler (`PLE NVMe table: 47.68 GiB`, danach `/health 200`; das erste
`503` liegt an der Warmup-Phase und wird vom Readiness-Loop abgedeckt).
Der Restore-Syntaxfehler in `run-ple-variant-matrix.sh` (Zeilen 161/162) ist
im Produktionsrepository laengst behoben (`bash -n` sauber, Produktions-Stand
2026-10-04T04:20). Neuer Befund: Der sofortige `benchmark_failed` von A erklaert
sich dadurch, dass das Produktions-`scripts/benchmark.sh` sein
`config/host.env` erst nach der Umgebungsubergabe einliest; die dort gesetzte
`PENNYROYAL_PORT=8001` ueberschreibt das vom Matrix-Runner uebergebene `8003`,
und die Messung lief gegen den laengst gestoppten Produktionsport. Das ist ein
Fehler im Produktionsrepository (ausserhalb dieses Branches) und dort als
offener Punkt zu beheben: Uebergabewerte vor dem `source` retten oder
`host.env` nur noch mit `:=`-Defaults fuellen.

## Risiken / offene Punkte

* CUDA-Graphs sind standardmaessig aus; der explizite Graph-Pfad (`TURBO_CUDA_GRAPH=on`)
  bleibt auf r24 wegen `Unsupported BCG output type: LogitsProcessorOutput`
  unbrauchbar und darf erst nach einem kompatiblen Backend-Update aktiviert
  werden. Eager-Ausfuehrung ist korrekt, aber langsamer.
* Breakable-Backend mit Mamba/NEXTN auf r24 bleibt ungetestet;
  Memory-Saver-Kollision moeglich (`TURBO_SLEEP_ON_IDLE=off`).
* io_uring-Seccomp-Profil bleibt Voraussetzung der Unit.
* io_uring-Latenz (~200 ms/Gaenger) wird durch A nicht besser - dafuer ist
  Variante B da.
* Kein Live-Test, kein Benchmark durchgefuehrt (bewusst, Geraetstatus).
