# Forschungsnotiz: Variante C (2026-10-04)

## Befund und Patch

Der dokumentierte Lauf `20261004T040547Z` erreichte Runtime-Readiness und
erfolgreiche Chat-Antworten. Auch Target-Verify- sowie Draft-Decode-/Extend-
CUDA-Graphs wurden aufgenommen. Der Lauf endete erst am zweiten
Benchmark-Gate: In `scripts/benchmark.sh` beendete `awk` seine Prometheus-
Pipeline vorzeitig; mit `pipefail` wurde `curl`'s Broken Pipe als Fehler
behandelt. Der Patch sammelt den letzten Metrikwert und gibt ihn nach Ende der
Eingabe aus. SSD-PLE und Decode-Graph-Verhalten bleiben unveraendert.

## Primaerquelle geprueft

* SGLang, [`cuda_graph_setup.py`](https://github.com/sgl-project/sglang/blob/main/python/sglang/srt/model_executor/model_runner_components/cuda_graph_setup.py), geprueft am 2026-10-04. Der Quelltext routet Prefill mit deaktiviertem Backend explizit zum EagerRunner und protokolliert die Deaktivierung. Das stuetzt den Befund, dass multimodales Prefill ohne Graph erwartbar sein kann; die Variante soll diese automatische Sicherheitsentscheidung nicht ueberschreiben.
* SGLang, [Multimodal Language Models](https://github.com/sgl-project/sglang/blob/main/docs/docs/supported-models/multimodal_language_models.mdx), geprueft am 2026-10-04. Die Dokumentation nennt CUDA-Graph-Inkompatibilitaet fuer bidirektionale multimodale Aufmerksamkeit. Das ist kein Beleg fuer genau dieses Modell, aber ein weiterer Grund, Prefill-Graphs nicht pauschal zu erzwingen.

## Bewertung und Gates

Kein plausibler Performance-Upstream-Patch wurde uebernommen und keine zusaetzliche
Variante angelegt: die verifizierte Ursache war ein lokaler Shell-Pipelinefehler,
nicht SSD-Reader oder CUDA-Capture. Erwarteter Gewinn des lokalen Patches: der
Benchmark-Runner liest den Busy-Wert ohne kuenstlichen Pipe-Abbruch. Risiko:
eine wirklich aktive Anfrage kann die Messung weiterhin verfaelschen; darum muss
der vorhandene Idle-Drain/Busy-Check wirksam bleiben.

Das automatische Prefill-Graph-Disable beizubehalten hat keinen erwarteten
Prefill-Durchsatzgewinn; es bewahrt stattdessen die korrekte multimodale
Ausfuehrung. Risiko einer spaeteren erzwungenen Aktivierung waeren falsche
Ergebnisse oder CUDA-Fehler. Decode-Graphs bleiben vom Patch unberuehrt.

Es gab in dieser Reparatursitzung keinen Runtime-Start, Healthcheck oder
Benchmark. Die Variante ist damit kein Produktionskandidat. Vor einer solchen
Einstufung sind Validate, kontrollierter Start, Health und Benchmark erneut zu
durchlaufen.
