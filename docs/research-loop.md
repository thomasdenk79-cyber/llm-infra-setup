# Forschungsnotizen: Variante B Healing

Stand: 2026-10-04

## EAGLE/XGrammar structured-output Warmup

**Beobachtung:** Der Run vom 2026-10-04 zeichnete Target-Verify-, Draft-Decode-
und Draft-Extend-CUDA-Graphs erfolgreich auf. Danach scheiterte der
`sm120_turbo_structured_output`-Warmup in `eagle_sample` beim Anwenden der
XGrammar-Bitmaske: 1 Logits-Zeile gegen 4 Maskenzeilen. Der mmap-PLE wurde zuvor
mit 47,68 GiB/320.001.536 Zeilen initialisiert.

**Primärquellen, geprüft am 2026-10-04:**

- [SGLang `bitmask_ops.py` auf GitHub](https://github.com/sgl-project/sglang/blob/main/python/sglang/kernels/ops/grammar/bitmask_ops.py): die
  Token-Bitmasken-Operation verlangt passende Batchdimensionen. Das erklärt,
  warum der protokollierte Shape-Mismatch ein Fehler und kein CUDA-Graph-Fehler
  ist.
- [SGLang `eagle_utils.py` auf GitHub](https://github.com/sgl-project/sglang/blob/main/python/sglang/srt/speculative/eagle_utils.py):
  EAGLE Sampling wendet die Grammar-Maske auf die Verify-Logits an.
- [Turbo-Upstream-Repository](https://github.com/mratsim/sglang-qwen38fn-sm120-turbo):
  das r24-Setup nutzt strukturierte Warmups als Teil des Startrezepts. Es gibt
  dort keinen verifizierten Patch fuer den konkreten Batchformfehler.

Die Code-Links auf `main` sind bewegliche Referenzen; maßgeblich fuer den
betroffenen Lauf bleibt die im Run verwendete, in `versions.lock` gepinnte
Turbo-Revision `c6cd5062669625fdbaf08032931f10b6661f8f6f` sowie der konkrete
Stacktrace in `/home/z000g9hu/work/llm-infra-setup/state/variant-runs/20261004T081939Z/B-attempt-1/journal.log`.

**Entscheidung / erwarteter Gewinn:** Variante B setzt `TURBO_WARMUPS=none`.
Der Reparaturpatch entfernt das zuvor doppelte feste `--warmups`-Argument,
sodass diese Einstellung tatsaechlich wirksam wird.
Der gemeinsame Launcher behaelt `sm120_turbo_structured_output` als Default.
Das vermeidet den bekannten fehlerhaften Request-Warmup und sollte den Start
bis zum Health-Endpunkt fortsetzen; es aendert weder Decode-Spekulation noch
CUDA-Graph-Capture oder SSD-PLE. Kein groesserer Kernel-/Upstream-Patch wurde
ungeprueft uebernommen.

**Risiko / Validierung:** Der Warmup-spezifische Kernelpfad wird nicht
vorgewaermt. CUDA-Graph-Capture ist durch die Logs belegt, aber Health und echte
strukturierte Ausgaben sind nach diesem Patch noch nicht geprueft. Es wurden
keine Pods gestartet und kein Benchmark ausgefuehrt. Erst nach den gleichen
Validate-, Start-, Health- und Benchmark-Gates darf die Variante als
Produktionskandidat gelten.

**Weitere Variante:** Keine neue Branch-/Worktree-Variante angelegt, weil kein
plausibler und verifizierter Upstream-Patch fuer den Masken-Batchfehler gefunden
wurde. Es sind keine zusaetzlichen Runner-Eintraege erforderlich.
