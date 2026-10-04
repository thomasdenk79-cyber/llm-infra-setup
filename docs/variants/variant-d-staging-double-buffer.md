# Variante D: Double-Buffer-Staging auf Basis von B

* Branch: `variant-d-staging-double-buffer` (aufgetropft auf `variant-b-mmap-pagecache`)
* Worktree: `~/work/llm-infra-setup-variant-d`
* Bild-Tag: `localhost/sglang-qwen38fn-sm120-turbo:r24-pr36567-variant-d`
* Port: 8005 (127.0.0.1), Container `sglang-turbo-variant-d`

## Idee

Der Reader in Variante B (mmap + LRU) hat einen verbleibenden Serialisierungs-
punkt: Der einzige gepinnte Staging-Puffer wird vor jeder `ctypes.memmove`
per `_stage_event.synchronize()` gegen die laufende H2D-Kopie des *vorherigen*
Schritts geschuetzt. Damit wartet der Modell-Thread bei jedem Decode-Schritt
auf die GPU-Kopie, die er gerade nicht braucht.

Variante D rotiert zwei Staging-Slots (`_stages`, `_stage_events`,
Round-Robin). Es muss nur das Event des Slots warten, das vor zwei Gathers
belegt wurde - laengst abgeschlossen, sobald die Schritte ~1 ms auseinander
liegen. Der Wegfall der Wartezeit ueberlappt CPU-Kopie mit H2D und FP8->BF16-
Dekodierung der GPU.

Bewusst **nicht** umgesetzt: ein stabiler GPU-Ausgabepuffer fuer den Capture-
Stub. Der Wrapper (`eager_on_graph`) haelt die Bridge-Ausgabe ohnehin stark
und die Vorlaufziffer laedt den Puffer ohnehin pro Formschluessel; ein
Modul-Cache wuerde Graph-Pools vermischen (Adressen aus Pool 1 in Graph 2)
und ist ein erkannte Gefahrenquelle ohne messbaren Nutzen.

## Geaenderte Dateien (gegenueber B)

* `config/turbo/pr36567-overlay/python/sglang/srt/models/qwen4_ple_nvme.py`
  - `_stage`/`_stage_event` -> Zwei-Slot-Listen `_stages`/`_stage_events`
  - `_stage_buffer()` liefert (Puffer, Slot) und synchronisiert nur das
    Slot-eigene Event
  - `finish_gather` zeichnet/synchronisiert das Event des benutzten Slots
* `scripts/54-install-sglang-turbo-variant-d.sh` (neu; wie 53, Tag/Port 8005)
* `docs/variants/variant-d-staging-double-buffer.md`, `mkdocs.yml`

## CUDA-Operationen im Capture / ausgeschlossen

identisch zu A/B (Capture-Stub verhindert CPU-I/O, Futures, Events und
Fremdstream-Kopien waehrend des nativen Captures). Die Events existieren nur
ausserhalb von Captures; im Breakable-Replay ist ihre Synchronisation
ausdruecklich vorgesehen.

## Start (spaeter, manuell)

```bash
cd ~/work/llm-infra-setup-variant-d
make turbo-c6-install
./scripts/54-install-sglang-turbo-variant-d.sh
./scripts/ple-preload.sh
systemctl --user daemon-reload
systemctl --user stop sglang-turbo-c6.service
systemctl --user start sglang-turbo-variant-d.service
curl -fsS http://127.0.0.1:8005/health
```

## Stop/Rollback

```bash
systemctl --user stop sglang-turbo-variant-d.service
systemctl --user start sglang-turbo-c6.service
```

## Messen

C1 und C6 gegen Port 8005 (wie in `docs/variant-comparison.md` beschrieben),
direkt gegen Variante B gemittelt - Erwartung: hohere `steady`-Raten erst
dann, wenn der LRU traegt (`mean_read_ms` klein); sonst aendert die
Doppel-Pufferung wenig, weil die SSD-Latenz dominiert.

## Risiken / offene Punkte

* Zwei gepinnte Puffer verdoppeln den Staging-Fussabdruck (~2 x
  `lookup_tokens * embedding_dim` Bytes); Groessenordnung Einzel-MiB.
* Die Slots wachsen unabhaengig; ein spaeterer langer Prompt verkleinert
  einen groessen Slot nicht (bewusst, vermeidet Allozieren im Schritt).
* Kein Live-Test, kein Benchmark durchgefuehrt.

## Healing-Lauf 2026-10-04

### Ursache

Der Start brach beim Capture des Decode-Runners ab. Das Breakable-CUDA-Graph-
Backend wollte ein `LogitsProcessorOutput` als BCG-Ausgabe puffern, unterstuetzt
diesen Typ in der verwendeten r24-Basis aber nicht (`TypeError`). Der SSD-PLE-
Manifest- und mmap-Pfad war zu diesem Zeitpunkt bereits erfolgreich geladen;
die 47,68-GiB-Tabelle mit 320.001.536 Zeilen ist daher nicht die Ursache.

### Minimaler Patch

Variante D setzt `TURBO_CUDA_GRAPH_BACKEND_PREFILL=disabled`. Das Startskript
reicht diese Einstellung explizit als `--cuda-graph-backend-prefill disabled`
weiter. Prefill laeuft damit eager, waehrend der Decode-Graph mit dem
Breakable-Backend erhalten bleibt; der mmap-PLE-Pfad und seine Doppel-Pufferung
werden nicht veraendert. Die Produktions-Unit und laufende Pods bleiben
unberuehrt.

### Restrisiko

Prefill verliert den Graph-Overheadvorteil und kann die Vorlaufzeit erhoehen.
Decode-Capture sowie SSD-PLE-Replay sind weiterhin nicht live verifiziert; vor
einer Produktionsentscheidung sind Start-, Health- und Benchmark-Gates noetig.
