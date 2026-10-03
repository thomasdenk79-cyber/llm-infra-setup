# Analyse: CUDA-Graph-Capture und SSD-PLE (Varianten A-D)

Diese Seite bündelt die Ursachenanalyse der vier vorbereiteten Varianten
(Read-only-Prüfung von Code, Bildinhalt und Protokollen; keine Benchmarks,
kein Start, keine Unit-Aenderungen). Die Variantezweige enthalten jeweils nur
ihren eigenen Patch; vergleichen wird über diese Tabelle:

| Variante | Branch | Worktree | Port | Bild-Tag | Zustand |
|---|---|---|---|---|---|
| A | `turbo-upstream-ple-graph` | `~/work/llm-infra-setup-turbo-upstream` | 8003 | `...variant-a` | Patches commitet, ungetestet |
| B | `variant-b-mmap-pagecache` | `~/work/llm-infra-setup-variant-b` | 8004 | `...variant-b` | wie A + mmap/LRU, ungetestet |
| C | `pennyroyal-plugin-variant` | `~/work/llm-infra-setup-pennyroyal` | 8001 | Pennyroyal-Bild | nur Konfiguration, ungetestet |
| D | `variant-d-staging-double-buffer` | `~/work/llm-infra-setup-variant-d` | 8005 | `...variant-d` | wie B + Double-Buffer, ungetestet |

Produktionsreferenz: `sglang-turbo-c6` (Port 8002, `--disable-cuda-graph`,
PLE mmap) mit ~31 tok/s C1 und ~78 tok/s pro Anfrage bei C6.

## 1. Warum `qwen4_exp.py` auf `_prefetch_stream` wartet

Der PLE-Lader ist als Vorholung gebaut: `start_prefetch()`
(`config/turbo/pr36567-overlay/python/sglang/srt/models/qwen4_exp.py:1277`)
stösst das Gather der PLE-Zeilen auf einem **zweiten CUDA-Stream**
(`_prefetch_stream`, Zeile 1112) an, während die vorherige Decoder-Schicht
noch läuft. Beim Verbrauch muss der Arbeitsstrom deshalb auf die Vorholung
warten, sonst lesen Key-/Value-Projektion halbkopierte Einbettungen:

* NVMe-Pfad: `finish_gather(..., stream=self._prefetch_stream)` (Zeile 1330)
  führt die H2D-Kopie des Pinning-Stagings auf genau diesem Stream aus.
* Der Join ist Zeile 1336: `torch.cuda.current_stream().wait_stream(self._prefetch_stream)` -
  **unbedingt**, ohne Erfassungsprüfung. Im Eager-Betrieb ist das korrekt und
  noetig; in der nativen CUDA-Graph-Erfassung wird derselbe Code
  mitaufgenommen (siehe Punkt 2).

Der Fremdstream existiert nur, wenn Auslagerungs-Einbettung oder NVMe-PLE
aktiv sind (Zeile 1112-1117) - deshalb trat der Fehler ausschliesslich auf
dem SSD-Pfad auf.

## 2. Warum die volle CUDA-Graph-Erfassung mit `cudaErrorStreamCaptureIsolation` scheitert

Zwei Ursachen, beide belegt:

1. **Fremdstream-Join im Capture.** Während der Erfassung läuft der
   NVME-Zweig von `start_gather()` nur durch den Capture-Stub
   (`qwen4_ple_nvme.py`, `_capture_start_gather`); auf `_prefetch_stream`
   wird nichts erfasst. Die Warmlauf-Kopien (Staging-H2D,
   `_stage_event`-Aufnahmen in `finish_gather`) bleiben aber als **nicht
   erfasste Arbeit** auf dem Fremdstream stehen. Das unbedingte
   `wait_stream` in Zeile 1336 erzeugt damit eine Abhaengigkeit des
   erfassenden Stroms auf nicht erfasste Arbeit - CUDA bricht die Erfassung
   mit `cudaErrorStreamCaptureIsolation` ab. Protokollauszuege dazu sind in
   `docs/HANDOFF.md` (Notizen 20:38/20:50) beschrieben.
2. **Defekter Capture-Guard.** `_capture_active()` (Stand production) prüfte
   `is_in_breakable_cuda_graph() or is_current_stream_capturing()`. Dieses
   Flag gilt in Breakable-Erfassung **und** Breakable-Replay. Im
   Breakable-Replay haette der Guard den echten Gather dauerhaft durch den
   Null-Stub (`_capture_finish_gather`, `output.zero_()`) ersetzt - die
   PLE-Ausgabe ware eingefrorene Null, ohne Fehlermeldung. Variante A
   ersetzt den Guard durch `_native_capture_active()`
   (nur `is_current_stream_capturing()`), versieht den Stub mit einer
   Einmal-Warnung (`_note_capture_stub`) und ueberlaesst Breakable-Replay
   absichtlich dem echten Eager-Koerper.

Zusatzbefund: mit vollem (`full`) Decode-Backend enthaelte der Graph nur den
Null-Stub, also statistisch saubere, aber inhaltlich falsche PLE-Ausgaben -
ein stiller Fehler, den die Warnung von Variante A sichtbar macht.

## 3. Warum Breakable-CUDA-Graphen fuer SSD-PLE erforderlich sind

Der SSD-Gather ist datenabhaengige CPU-/IO-Arbeit, die physikalisch nicht in
einen Graphen passt (alle Stellen in
`config/turbo/pr36567-overlay/python/sglang/srt/models/qwen4_ple_nvme.py`):

* `start_gather()`: `input_ids ... .to(device="cpu").tolist()` -
  synchroner GPU->CPU-Kopien; waehrend der Erfassung verboten.
* `ThreadPoolExecutor.submit(...)` + `finish_gather()`:
  `pending.future.result()` - blockierendes Warten auf eine Workerthread-Datei,
  Token-IDs existieren erst zur Replay-Zeit.
* `ctypes.memmove` in den gepinnten staging-Puffer, H2D-Kopie,
  FP8->BF16-Dekodierung, `_stage_event.synchronize()` -
  Ereignissynchronisation ist innerhalb der Erfassung unerlaubt.

Breakable-Graphen (`--cuda-graph-backend-decode=breakable`) erlauben
Eager-Inseln im Graph (`eager_on_graph` mit Capture-Stubs): Attention,
MoE und Faltungswege bleiben im Graph (das bringt die Rate), der
SSD-Abschnitt laeuft echt weiter. Genau deshalb ist Breakable die einzige
 sinnvolle Betriebsart fuer SSD-PLE; `full` liefert nur Null-Stubs,
 `--disable-cuda-graph` (Produktion) wirft alles Graphische ueber Board -
 das ist der Grund, warum die Referenz bei ~31 tok/s C1 klebt.

## 4. Geschwindigkeitsprognose

Grundprobleme der Referenzmessung (Log `mean_read_ms=199,9` pro Gather bei
~720 Zeilen): QD1-Folgesuchen, ein IO-Worker, blockierendes
`future.result()`, Einzel-Staging-Puffer mit Ereignis-Stall;
io_uring-Seitencache Standard 0.

| Variante | Erwartung | Begruendung |
|---|---|---|
| **B** (schnellste Turbo-Variante) | deutlich ueber A | mmap/Page-Cache + begrenzter Zeilen-LRU + Vorladen (`ple-preload.sh`) drueckt `mean_read_ms` weit unter 200 ms; Sync-Modus entfernt Thread-/Future-Overhead |
| **D** | >= B | zusaetzliche Rotation zweier gepinnter staging-Puffer entfernt den Ereignis-Stall pro Schritt; gewinnt nur, wenn Staging (nicht IO) dominiert - isolierbar durch Direktvergleich B gegen D |
| **A** | ueber 31 tok/s, unter B | beweist nur die Capture-Korrektheit; io_uring-Latenz (~200 ms) bleibt, Ueberlappung muss greifen |
| **C** (Referenz, moeglicher Gesamtbestwert) | kann B/D uebertreffen | Bild-Plugin mit nativem Rust-io_uring-Lader, rotierenden staging-Slots und Vor-Capture-Hooks; keine eigene Python-Staging-Schleife |

Zielwerte laut `docs/performance.md`: C1 ~160-200 tok/s, C6 klar ueber
78 tok/s pro Anfrage. Pro Variante drei Messungen, Median, getrennt
TTFT / stabil pro Anfrage / Aggregat (Auftragstext in
`docs/variant-test-prompt.md`).

## 5. Pennyroyal-Plugin-Hook vs. Turbo-PLE-Lader (Graph-Sicherheit)

Bildinhalt am 2026-10-03 per `podman cp` aus
`ghcr.io/jpezzulli/sglang-rtxpro6000:v2.5.3` gepueft (Container wurde
**nie gestartet**): `/opt/pennyroyal/.ple-nvme/sglang_ssd_stream` ist
vorhanden und gebaut (`0.2.0+pennyroyal2`),
`/opt/pennyroyal/scripts/pennyroyal/check_ple_nvme.py` ebenso. Die
Vorbedingung von `config/pennyroyal/ple-backend.sh` ist damit erfuellt.

Der Plugin-Ansatz ist strukturell graph-sicherer als der (geflickte)
Turbo-Lader:

* **Erfassung bleibt IO-frei.** `begin_gather()` wirft innerhalb der
  Erfassung expressiv (`backend.py`: "SSD Stream I/O must be prepared
  outside CUDA graph capture") - Fail-loud statt stub-geteilter Wahrheit.
* **Kein Fremdstream-Join im Graph.** `Qwen4PLELayer.start_prefetch()`
  (`qwen4.py:107`) ersetzt im Capture den `wait_stream`-Join durch ein
  `_GraphCaptureTicket`, das lediglich `wait_event` auf ein externes
  CUDA-Ereignis erfasst; der Turbo-Lader Join-ed einen Stream mit
  nicht erfasster Arbeit (Ursache 2.1).
* **SSD-Arbeit liegt ausserhalb, zwischen load_batch und Replay.** Die Hooks
  `around_execute`/`after_load_batch` (`graph.py`) rufen
  `prepare_ssd_stream_graph_replay()` auf, das die Zeilen auf dem
  Vorholstream fuellt und erst dann das Replay einleitet; Synchronisation
  laeuft ueber erneut aufgezeichnete Abschluss-Ereignisse.
* **Double-Buffering eingebaut.** `_acquire_slot()` rotiert vorverteilte
  staging-Slots mit Eigen-Ereignissen - Variante D holt das fuer Turbo erst
  nach; der Turbo-Lader blockiert zusaetzlich mit `future.result()` im
  Verbraucherpfad.
* **Registrierung erzwungen.** `plugin.py` bricht beim Start ab, wenn ein
  Pflicht-Hook fehlt (`_install_required_hook_enforcement`) - ein
  halb installierter Adapter kann nicht unbemerkt die falsche PLE laden.

Restrisiko Plugin: Abhaengig von Pennyroyal-Bild und -Pflege (Digest in
`versions.lock`), Vor-Capture-Staging verlagert Latenz in den
load_batch-Pfad, und die H2D->Replay-Reihenfolge haengt an der korrekten
Ereigniszeichnung im Hook (Upstream SSD Stream v0.2.0, unveraendert; die
BF16-Staging-Hotfix-Doku zeigt, dass dort frueher Kapazitaetsfehler auftraten
- in FP8 und v2.5.3 als behoben dokumentiert).

## Patchdetails je Variante (Kurzfassung)

* **A** (`06ed8eb`): `qwen4_exp.py` - `wait_stream` nur noch, wenn nicht in
  nativer Erfassung und kein NVMe-Stub laeuft; `qwen4_ple_nvme.py` - Guard
  auf `_native_capture_active()`, Einmal-Warnung statt stillem Null-Stub;
  Install-Skript 52 mit Graph-Strategie-Umschalter (breakable Decode).
* **B** (`de6f24e`): auf A - Zeilen-LRU fuer `MMapRowReader`
  (`SGLANG_QWEN4_PLE_NVME_MMAP_CACHE_MB`), Sync-Vorholmodus
  (`SGLANG_QWEN4_PLE_NVME_PREFETCH=sync`, kein Workerthread/Future),
  Vorladen ueber `scripts/ple-preload.sh` vor dem Start; Install-Skript 53.
* **D** (`3ccf3ae`): auf B - zwei rotierende gepinnte staging-Puffer mit
  Slot-Ereignissen; der CPU-Kopie eines Gather wartet nur noch auf das
  Ereignis des vor zwei Schritten benutzten Slots; Install-Skript 54.
* **C** (`625c1e8`, `73c47bd`): keine Code-Aenderung am Bild -
  `config/pennyroyal/ple-backend.sh` (neu), Quadlet-Mount und Umgebungs-
  werte (`PENNY_PLE_BACKEND=nvme`, Manifest-Pruefung, NAMESPACE-Felder),
  Defaults in `scripts/50-install-pennyroyal.sh`.

## Risiken

* **A/D (io_uring):** braucht die freigegebene Seccomp-Regel
  (`io_uring_setup/enter/register`); sonst EPERM -> Rueckzug auf
  `SGLANG_QWEN4_PLE_NVME_BACKEND=mmap`.
* **B:** Page-Cache kann ARC/Arbeitsspeicher verdaengen; LRU-Deckel (Unit:
  512 MiB) einhalten, Vorladen nur vor dem Start. Sync-Modus kostet
  Ueberlappung - bei schwachem Cache kann A/B mit async schneller sein.
* **D:** zweiter gepinnter Puffer erhoht fest reservierten Host-Speicher.
* **Breakable allgemein:** Eager-Inseln kosten Erfassungsvorteile; bei
  Schlafmodus-Konflikt `NotImplementedError ... memory saver` ->
  `TURBO_SLEEP_ON_IDLE=off` im Generator der Variante setzen.
* **C:** laeuft nur, wenn prepared NVMe-Artefakt
  (`PENNY_PLE_NVME_MODEL`) und Manifestpruefung durchlaufen; bricht sonst
  kontrolliert ab (dokumentiertes Ergebnis, kein Bug dieses Repos).
* **Alle:** GPU ist exklusiv (ADR 0013) - vor jedem Start
  `sglang-turbo-c6` stoppen und Pruefung mit
  `nvidia-smi --query-compute-apps=pid`; kein Benchmark bei fremdem
  GPU-Besitz.

## Empfohlene Testreihenfolge

1. **A** - Beweisziel: Erfassung laeuft durch, `cuda graph: True`, keine
   "uncaptured work"-Meldung, Breakable-Decode aktiv.
2. **B** - hoechste Turbo-Rate erwartet; `mean_read_ms << 200` im Startlog
   nach `ple-preload.sh` verifizieren.
3. **D** - Direktvergleich gegen B (gleiche Parameter); nur die
   Staging-Aenderung entscheidet.
4. **C** - unabhaengige Referenz des offiziellen Pfads; bricht sie mangels
   Artefakt ab, ist das ein dokumentiertes Ergebnis.

Immer: eine Variante, GPU exclusiv, drei Messungen pro Konfiguration
(C1 und C6 getrennt), Rueckbau und Produktionsdienst danach zurueck,
Checkpoint je Schritt. Der vollstaendige, kopierfertige Auftragstext
(inkl. Fehlerbildern) liegt in `docs/variant-test-prompt.md`; je
Variantenzweig zusaetzlich in `docs/variants/`.
