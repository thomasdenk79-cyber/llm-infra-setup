# Variante A: Turbo-Upstream mit graph-sicherem PLE-Pfad

Isolierter Vergleichsdienst fuer das Turbo-r24-Rezept (Port 8003, Container
`sglang-turbo-upstream-ple`). Das Startrezept bleibt gegenueber
`config/turbo/serve-qwen38-flash-next-c6.sh` unveraendert: TP1, Online-MXFP8,
NEXTN/MTP, HiCache und KV-FP8 bleiben an. CUDA-Graphs sind **aktiviert**
(Default: Decode-Backend `breakable`). Die einzige Laufzeiterweiterung ist der
PR36567-SSD-PLE-Reader plus der graph-sicheren Overlayerweiterung unten.

## Diagnose: warum der Capture bisher abstuerzte

Protokollauszug (journalctl, 20:38 und 20:50, identisch):

```text
qwen4_exp.py:1336  torch.cuda.current_stream().wait_stream(self._prefetch_stream)
torch/cuda/streams.py  wait_stream -> self.wait_event(stream.record_event())
torch.AcceleratorError: CUDA error: dependency created on uncaptured work in another stream
  (= cudaErrorStreamCaptureIsolation)
Exception: Capture cuda graph failed  (full_cuda_graph_backend.py:128 capture_one)
```

Ursache, konkret:

1. `full_cuda_graph_backend.capture_one` captuert den Decode-Forward auf
   `self._capture_stream`, nachdem es zwei Eager-Warmlaeufe gefahren hat.
2. In diesen Warmlaeufen legt `qwen4_ple_nvme.finish_gather()` die H2D-Kopien
   auf den Fremdstream `Qwen4ExpPLELayer._prefetch_stream` (Zeilen 612-621)
   und zeichnet ein Event darauf.
3. Im eigentlichen Capture laeuft fuer den NVMe-Pfad nur der Capture-Stub
   (Zeilen 431-434, 444-456); der Fremdstream wird im NVMe-Zweig **nie** per
   `stream.wait_stream(current)` in das Capture hineingezweigt
   (`start_prefetch` zweigt nur den UVA-Zweig, qwen4_ple_nvme.py:1314).
4. `_consume_prefetched_embeddings` joinnte den Fremdstream trotzdem
   unbedingt (qwen4_exp.py:1336). Die Capture-Strom wartet damit auf ein
   Event eines nicht erfassten Stroms mit waermelauf-restarbeiten ->
   `cudaErrorStreamCaptureIsolation`, Capture invalidiert, Dienst stirbt.

Zweiter, lauterer Defekt: Der Guard `_capture_active()` prüfte
`is_in_breakable_cuda_graph()`. Dieses Flag (context.py) gilt in BCG-Capture
**und** BCG-Replay. Beim Replay rufen die Break-Funktionen die echten
`start_/finish_gather`-Koerper auf, der Guard lieferte dort trotzdem den
Null-Stub -> PLE-Ausgabe dauerhaft null, und der fuer Replay gedachte
Event-Sync (`finish_gather`, Zeile 622ff.) war unerreichbar.

Dritter Befund: Mit dem `full`-Decode-Backend enthaelt das erfasste Graph nur
den Null-Stub; das Replay fuehrt nie echte SSD-Zeilen aus. Korrekte PLE-Werte
mit Graphen gibt es nur mit dem Breakable-Backend, weil dort die echten
Koerper als Break-Funktionen im Replay laufen.

## Fix in dieser Variante (Code im Overlay)

* `qwen4_ple_nvme.py`: `_capture_active()` -> `_native_capture_active()`,
  prueft nur noch `torch.cuda.is_current_stream_capturing()` (nativer
  Capture); Breakable-Capture uebernimmt der Dekorkator-Stub, Breakable-
  Replay laeuft bewusst den echten Koerper. Eine Warnung (`_note_capture_stub`)
  meldet einmalig, wenn ein volles Graph den Null-Stub aufzeichnet.
* `qwen4_exp.py`: Join in `_consume_prefetched_embeddings` nur noch, wenn
  entweder der UVA-Pfad laeuft (`pending_nvme is None`) oder gerade kein
  nativer Capture aktiv ist. Damit bleibt der UVA-Join im Capture erhalten
  (dort legal, da der Stream angezweigt wurde), der NVMe-Join entfaellt.

## Build und Start (manuell, Betreiberaktion)

```bash
cd ~/work/llm-infra-setup-turbo-upstream
make turbo-c6-install                       # Basisbild r24, nur falls fehlend
./scripts/52-install-sglang-turbo-upstream-ple.sh   # Overlaybild + Unit, Port 8003
systemctl --user daemon-reload
systemctl --user start sglang-turbo-upstream-ple.service
journalctl --user -u sglang-turbo-upstream-ple.service -f
curl -fsS http://127.0.0.1:8003/health
```

Der Vergleich laeuert exclusiveGPU: vorher Produktions-Turbo stoppen
(`systemctl --user stop sglang-turbo-c6.service`), nachher zurueck.

Stop/Rollback:

```bash
systemctl --user stop sglang-turbo-upstream-ple.service
systemctl --user start sglang-turbo-c6.service
```

## Schalter (Umgebungsvariablen der Unit)

| Variable | Werte | Bedeutung |
|---|---|---|
| `TURBO_CUDA_GRAPH` | `on` (Default) / `off` | `off` = `--disable-cuda-graph` wie bisher |
| `TURBO_CUDA_GRAPH_BACKEND_DECODE` | `breakable` (Default) / `full` | Decode-Backend; `full` zeigt nur den Null-Stub (Warnung im Log) |
| `TURBO_SLEEP_ON_IDLE` | `on` (Default) / `off` | `off` noetig, falls Breakable + Memory-Saver kollidieren |
| `SGLANG_QWEN4_PLE_NVME_BACKEND` | `io_uring` (Unit-Default) / `mmap` | Upstream-Lesepfad; mmap siehe Variante B |

## Was waehrend des Captures laufen darf (und was der Code sicherstellt)

* Erlaubt: Kernel auf dem Capture-Strom (Attention, Mamba, MoE, Zero-Stub des
  PLE), Zuweisungen aus dem Graph-Pool.
* Ausgeschlossen im nativen Capture: mmap-/io_uring-Zugriffe,
  ThreadPoolExecutor-Arbeit, `future.result()`, H2D-Kopie, Event-Records auf
  Fremdstreams, `wait_stream` auf einen nicht angezweigten Strom.
  Erzwungen durch: `_native_capture_active()`-Guard vor jedem CPU-I/O in
  `start_gather`/`finish_gather` und den bedingten Join in qwen4_exp.py.
* Im Breakable-Replay ist CPU-/SSD-Arbeit ausdruecklich erlaubt - die
  Abschnitte laufen ohnehin ausserhalb jeder Capture.

## Messen

C1 und C6 getrennt, jeweils gegen Port 8003 (vorher Produktions-Turbo stoppen):

```bash
PENNYROYAL_PORT=8003 BENCHMARK_MODEL=Qwen3.8-Flash-Next \
  ./scripts/benchmark.sh quick 1     # C1: TTFT + steady tok/s
PENNYROYAL_PORT=8003 BENCHMARK_MODEL=Qwen3.8-Flash-Next \
  ./scripts/benchmark.sh quick 6     # C6: dazu aggregierter Durchsatz
```

Im Startlog erwartet: `cuda_graph=on/breakable`, spater `cuda graph: True`
in den Decode-Zeilen, und `Qwen4 PLE NVMe: ... mean_read_ms=` ohne
Capture-Fehlermeldungen.

## Risiken und offene Punkte

* Breakable mit NEXTN/MTP und Mamba-Layern ist auf dieser Turbo-Revision noch
  nicht live getestet (erwartete Fehler: Capture der Draft-Laeufe,
  Memory-Saver-Kollision -> dann `TURBO_SLEEP_ON_IDLE=off`).
* `io_uring` braucht das Seccomp-Profil der Unit (wie beim Produktionsdienst).
* Bei Abbruch im Capture: Logauszug sichern, Zustand ist unveraendert, da das
  Bild ein eigenes Tag (`:r24-pr36567-variant-a`) nutzt.
* Die BCG-Break-Funktionen replizieren die PLE-Ausgabe in das Bridge-Buffer
  (`_copy_output`); die Zusatzkopie pro Schritt ist messbar, aber noetig.
