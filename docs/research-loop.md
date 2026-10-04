# Forschungsnotiz: Variante D Healing (2026-10-04)

## Gepruefter Ansatz

Die primaere SGLang-Quelle dokumentiert getrennte CUDA-Graph-Backends fuer
Prefill und Decode und zeigt, dass `--cuda-graph-backend-prefill=disabled` den
Prefill-Graphen auf den EagerRunner routet:

* SGLang `cuda_graph_setup.py`, abgerufen am 2026-10-04:
  <https://github.com/sgl-project/sglang/blob/main/python/sglang/srt/model_executor/model_runner_components/cuda_graph_setup.py>
* SGLang `cuda_graph_config.py`, abgerufen am 2026-10-04:
  <https://github.com/sgl-project/sglang/blob/main/python/sglang/srt/model_executor/cuda_graph_config.py>

Der Trace zeigt jedoch den Fehler im `capture_decode_graph`: r24 versucht dort
den Breakable-Backend mit `LogitsProcessorOutput` zu puffern. Prefill allein zu
deaktivieren waere deshalb unzureichend. D setzt den vorhandenen Eager-Schalter
`TURBO_CUDA_GRAPH=off`; der SSD-PLE-Pfad bleibt real aktiv und wird nicht durch
einen Full-Graph-Stub ersetzt.

**Erwarteter Gewinn:** Der Start kommt am nicht unterstuetzten BCG-Ausgabetyp
vorbei; SSD-PLE bleibt korrekt aktiv.

**Risiko:** Prefill und Decode sind eager und koennen TTFT sowie Durchsatz
verschlechtern. Die Quelle nennt keine Garantie fuer diese r24-Sonderbasis;
Start, Health und Benchmark muessen daher als Kandidatengates erneut laufen.
Es wurde kein zusaetzlicher Forschungsbranch angelegt, weil der Ansatz eine
punktuelle Konfigurationskorrektur der bestehenden Variante ist.
