# Testauftrag: Turbo/PLE-Varianten starten und messen (Cloud-Agent)

Dieser Text ist der eigenständige Auftrag für einen Agenten, der die vier
vorbereiteten Varianten nacheinander live startet, misst und dokumentiert.
Er ergänzt `AGENTS.md` (Grundregeln gelten unverändert: GPU exclusiv, keine
Zerstörung, Units nur über Skripte, nichts ohne Checkpoint).

---

## Auftragstext (kopierbar)

```text
Du testest die Turbo/PLE-Varianten des Repository llm-infra-setup.

Ausgangslage (vorher lesen):
- AGENTS.md (Grundregeln), docs/HANDOFF.md (Sofortlage),
  docs/variant-comparison.md (Tabelle + Status), docs/variants/*.md.
- Produktionsstand: Branch turbo-c6-production, Dienst sglang-turbo-c6 auf
  Port 8002, Läuft stabil mit --disable-cuda-graph (PLE backend mmap).
  Referenzmessungen: ~31 tok/s C1, ~78 tok/s pro Anfrage bei C6.
- Diagnose (behoben in den Varianten, hier nicht nochmal suchen):
  1) qwen4_exp.py:1336 joined den Fremdstream _prefetch_stream unbedingt im
     nativen CUDA-Graph-Capture -> cudaErrorStreamCaptureIsolation.
  2) _capture_active() verwechselte Breakable-Capture mit -Replay ->
     PLE ware im Graph-Replay dauerhaft null.
  3) mean_read_ms~200 pro Gather: QD1-Lesen, 1 IO-Worker, blockierendes
     future.result(), Einzel-Staging-Puffer.

Arbeitsregeln:
- Immer nur EINE Variante mit GPU. Vor jedem Start:
    systemctl --user stop sglang-turbo-c6.service   (und Pennyroyal aus)
  Nach jedem Test zuruck:
    systemctl --user start sglang-turbo-c6.service
- Kein Benchmark, solange ein anderer GPU-Dienst laeuft (pruefen:
    nvidia-smi --query-compute-apps=pid --format=csv,noheader).
- Vor jedem Zwischenstand: ./scripts/session-checkpoint.sh "Notiz".
- Bei Absturz/Fehlschlag: Journal-Auszug (journalctl --user -u <unit>
  -n 200) in state/ sichern, Messung verwerfen, naechste Variante.
- Keine Units manuell editieren; alles ueber die scripts/5x-Skripte.
- Kein zfs destroy / mkfs / Loeschoperationen. Modelle unveraendert.

Reihenfolge und Erwartung (Details in docs/variant-comparison.md):
1) A 'turbo-upstream-ple-graph' (Worktree ~/work/llm-infra-setup-turbo-upstream,
   Port 8003, Bildtag ...variant-a). CUDA-Graphs AN, Decode-Backend
   breakable. Beweisziel: Capture laeuft durch, "cuda graph: True",
   keine "uncaptured work"-Meldung. Erwartung: deutlich ueber 31 tok/s C1;
   io_uring-Latenz (~200 ms/Gather) bleibt, Ueberlappung muss greifen.
2) B 'variant-b-mmap-pagecache' (Port 8004, Tag ...variant-b). wie A, aber
   mmap/Page-Cache + begrenzter LRU (Unit: 512 MiB). Kein Vorladen:
   ./scripts/ple-preload.sh waermt nur das Pennyroyal-native Artefakt
   (PENNY_PLE_NVME_MODEL, layer-0.bin/layer-*.safetensors) und ist kein
   Turbo-Safetensors-Preloader. Erwartung: moeglicher Cache-Gewinn, nur
   messbar an mean_read_ms und getroffenem Page-Cache-Anteil.
3) D 'variant-d-staging-double-buffer' (Port 8005, Tag ...variant-d). wie B
   plus Double-Buffer-Staging (kein Event-Stall pro Schritt). Nur sinnvoll
   nach B; Vergleich B gegen D isoliert den Staging-Effekt (moeglicher
   Staging-Gewinn).
4) C 'pennyroyal-plugin-variant' (Pennyroyal Port 8001, Bild-Plugin
   ssd_stream, PENNY_PLE_BACKEND=nvme). strukturell vielversprechend und
   unabhaengige Referenz des offiziellen Pfads; bricht sie fehl
   (Plugin/Manifest fehlt im Bild), ist das ein Ergebnis, kein Bug dieses
   Repos.

Eine Rangfolge der Rate ist vor den Messungen unbekannt; keine Erwartung an
einen Variantenrang im Vorfeld berichten, nur die vier Einordnungen
(C strukturell vielversprechend, B moeglicher Cache-Gewinn, D moeglicher
Staging-Gewinn, A Capture-Referenz).

Messprotokoll pro Variante (identisch halten):
a) Build/Unit:
     cd <worktree>
     make turbo-c6-install          # nur falls Basisbild r24 fehlt
     <install-Skript aus der varianten-doc>
b) Start und Bereitschaft:
     systemctl --user daemon-reload
     systemctl --user start <unit>
     ./scripts/wait-for-runtime.sh  (Port der Variante; Timeout 2400s)
     curl -fsS http://127.0.0.1:<port>/health
   Im Startlog prüfen: cuda_graph=on/breakable, cuda graph: True,
   Qwen4 PLE NVMe: ... mean_read_ms=... (Wert protokollieren).
c) Messung C1 und C6 getrennt (TTFT, steady tok/s pro Anfrage,
   aggregierte tok/s - drei Zahlen getrennt ausweisen):
     PENNYROYAL_PORT=<port> BENCHMARK_MODEL=Qwen3.8-Flash-Next \
       ./scripts/benchmark.sh quick 1
     PENNYROYAL_PORT=<port> BENCHMARK_MODEL=Qwen3.8-Flash-Next \
       ./scripts/benchmark.sh quick 6
   Jede Messung 3x wiederholen; Median berichten; state/benchmarks/
   sichern und nach docs/ (bzw. HANDOFF-Auszug) kopieren.
d) Rueckbau der Variante, Produktionsdienst zurueck, Checkpoint.

Fehlerbilder und Reaktionen:
- "dependency created on uncaptured work": Diagnose unvollstaendig ->
  Log + Traceback in state/logs/, Variante gilt als nicht behoben.
- NotImplementedError "Breakable ... memory saver": TURBO_SLEEP_ON_IDLE=off
  in die Unit-Umgebung des Install-Skripts eintragen (im Generator aendern,
  Unit neu erzeugen, committen).
- io_uring EPERM: seccomp-io-uring.json pruefen; fuer Turbo auch mmap
  (SGLANG_QWEN4_PLE_NVME_BACKEND=mmap) als Rückzug.
- OOM/VRAM: mem-fraction NICHT eigenmaechtig senken; Zustand sichern,
  Betreiberentscheid (docs/performance.md, ADR 0013).

Abnahme:
- Empfehlung an den Betreiber: beste Variante begruendet mit Zahlenmatrix
  (TTFT / steady pro Anfrage / aggregat, jeweils C1 und C6),
  mit Logauszuegen (cuda graph: True, mean_read_ms).
- docs/variant-comparison.md Status-Tabelle auf "getestet" ziehen,
  CHANGELOG.md und docs/status.md nachziehen,
  ./scripts/session-checkpoint.sh abschliessen (committen + pushen).
```

---

## Kurzfassung fuer den Betreiber

Starte mit **A** (beweist die Capture-Korrektur, Capture-Referenz). Eine
Rangfolge der Schreibrate ist **ohne Benchmark unbekannt**; die Einordnungen
sind: **C** strukturell vielversprechend, **B** ein moeglicher Cache-Gewinn,
**D** ein moeglicher Staging-Gewinn. Vor der Messung aller vier
Konfigurationen gehoert keine Rangfolge in Berichte. Zielwerte laut
`docs/performance.md`: C1 ~160-200 tok/s, C6 deutlich ueber 78 tok/s pro
Anfrage.
