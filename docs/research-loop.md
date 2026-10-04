# Forschungsnotizen: Variante B Healing

Stand: 2026-10-04

## EAGLE/NEXTN Verify und XGrammar Batchformen

**Beobachtung:** Die Runs vom 2026-10-04 zeichnen Target-Verify-, Draft-Decode-
und Draft-Extend-CUDA-Graphs erfolgreich auf und initialisieren den mmap-PLE
mit 47,68 GiB/320.001.536 Zeilen. Versuch 1 endet beim strukturierten Warmup
mit 1 Logits-Zeile gegen 4 XGrammar-Maskenzeilen. Versuch 2 ohne den Warmup
endet bei EAGLE `target_predict.reshape(1, 4)`, obwohl nur ein Wert vorliegt.
Die erste Abweichung allein koennte ein Warmup/XGrammar-Problem sein; der
zweite Stacktrace zeigt den umfassenderen NEXTN/EAGLE-Verify-Shape-Fehler.

**Primärquellen, geprüft am 2026-10-04:**

- [SGLang Issue #24283](https://github.com/sgl-project/sglang/issues/24283),
  geprüft am 2026-10-04: dokumentiert einen Scheduler-Absturz bei
  EAGLE/NEXTN plus `response_format`/XGrammar. Das Symptom liegt im selben
  Integrationsbereich, der dort beschriebene TypeError ist aber nicht identisch
  mit den hier beobachteten Tensor-Shapes; es gibt keinen uebertragbaren
  verifizierten Patch.
- [SGLang `eagle_utils.py`](https://github.com/sgl-project/sglang/blob/main/python/sglang/srt/speculative/eagle_utils.py)
  und [`bitmask_ops.py`](https://github.com/sgl-project/sglang/blob/main/python/sglang/kernels/ops/grammar/bitmask_ops.py),
  geprüft am 2026-10-04: primaere Codepfade fuer EAGLE-Verifikation und
  Bitmaskenanwendung; `main` ist beweglich und wurde nicht als Patchquelle
  behandelt.
- [Turbo-Upstream-Repository](https://github.com/mratsim/sglang-qwen38fn-sm120-turbo),
  geprüft am 2026-10-04: r24-Basis fuer das Startrezept, ohne identifizierten
  Fix fuer den protokollierten Shape-Fehler.

Die Code-Links auf `main` sind bewegliche Referenzen; maßgeblich fuer den
betroffenen Lauf bleibt die im Run verwendete, in `versions.lock` gepinnte
Turbo-Revision `c6cd5062669625fdbaf08032931f10b6661f8f6f` sowie der konkrete
Stacktrace in `/home/z000g9hu/work/llm-infra-setup/state/variant-runs/20261004T081939Z/B-attempt-1/journal.log`.

**Entscheidung / erwarteter Gewinn:** Variante B setzt `TURBO_SPECULATIVE=off`.
Der varianteigene Launcher laesst dadurch NEXTN/EAGLE-Parameter weg, behaelt
aber Breakable-Decode-CUDA-Graphs und den SSD-mmap-PLE-Pfad. Das verhindert
den durch beide Logs belegten EAGLE-Verify-Absturz; erwarteter Gewinn ist ein
Serverstart und eine funktionierende normale Inferenz, bei geringerem
Durchsatz durch fehlende spekulative Dekodierung. CUDA Graph bleibt fuer den
Target-Decode aktiv. Kein Kernel-/Upstream-Patch wurde ungeprueft uebernommen.

**Risiko / Validierung:** NEXTN-Durchsatz geht verloren; der funktionierende
Eager-Target-Pfad innerhalb des Breakable-Graph-Backends plus mmap-PLE braucht
noch Start-, Health- und Inferenznachweis. Es wurden keine Pods gestartet und
kein Benchmark ausgefuehrt. Erst nach Validate-, Start-, Health- und
Benchmark-Gates darf die Variante Kandidat werden.

**Weitere Variante:** Keine neue Branch-/Worktree-Variante angelegt, weil kein
plausibler und verifizierter Upstream-Patch fuer den Masken-Batchfehler gefunden
wurde. Es sind keine zusaetzlichen Runner-Eintraege erforderlich.
