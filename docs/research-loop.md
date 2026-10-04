# Forschungsnotiz: Variante D Healing (2026-10-04)

## Gepruefter Ansatz

Die primaere SGLang-Quelle dokumentiert getrennte CUDA-Graph-Backends fuer
Prefill und Decode und zeigt, dass `--cuda-graph-backend-prefill=disabled` den
Prefill-Graphen auf den EagerRunner routet:

* SGLang `cuda_graph_setup.py`, abgerufen am 2026-10-04:
  <https://github.com/sgl-project/sglang/blob/main/python/sglang/srt/model_executor/model_runner_components/cuda_graph_setup.py>
* SGLang `cuda_graph_config.py`, abgerufen am 2026-10-04:
  <https://github.com/sgl-project/sglang/blob/main/python/sglang/srt/model_executor/cuda_graph_config.py>

Das passt direkt zum Beleg: r24 versucht trotz der Auto-Disable-Meldung den
Breakable-Prefill-Runner und scheitert an `LogitsProcessorOutput`. Der Patch
setzt deshalb nur in Variante D den Prefill-Backend explizit auf `disabled`;
der Decode-Backend bleibt `breakable` fuer den SSD-PLE-Replaypfad.

**Erwarteter Gewinn:** Start/Capture kommt am nicht unterstuetzten Prefill-
Ausgabetyp vorbei; SSD-PLE und Decode-CUDA-Graphs bleiben aktiv.

**Risiko:** Prefill ist eager und kann TTFT erhoehen. Die Quelle nennt keine
Garantie fuer diese r24-Sonderbasis; Start, Health und Benchmark muessen daher
als Kandidatengates erneut laufen. Es wurde kein zusaetzlicher Forschungsbranch
angelegt, weil der Ansatz eine punktuelle Konfigurationskorrektur der bestehenden
Variante ist.
