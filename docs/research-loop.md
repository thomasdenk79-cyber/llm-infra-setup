# Forschungsloop für SSD-PLE und CUDA Graphs

Die Variantenmatrix ist als kontrollierter Forschungsloop gedacht. Heiler dürfen
aus Logs und Code neue Ansätze ableiten und weitere Kandidaten vorschlagen, wenn
eine Kombination aus Upstream-Patch, CUDA-Verfahren, SGLang-Änderung oder Plugin
einen plausiblen Gewinn verspricht.

## Regeln

1. Primärquelle prüfen: offizielles Repository, Release, Dokumentation oder Paper.
2. Quelle, Abrufdatum, erwarteten Gewinn und Restrisiko festhalten.
3. Jeden neuen Ansatz in einem eigenen Branch und Worktree isolieren.
4. Produktions-Units und den aktuell guten Kandidaten unverändert lassen.
5. Vor einer Übernahme dieselben Gates ausführen: `make validate`, `make drift`,
   Start, `/health`, C1- und C6-Benchmark.
6. Nur messbar bessere Kandidaten dürfen als neue Referenz vorgeschlagen werden;
   bei Verschlechterung bleibt der bisherige Referenzstand aktiv.
7. Ein bestandener Matrixlauf erzeugt automatisch einen Benchmarkbericht mit allen
   verfügbaren C-Profilen, KV-Cache-/HiCache-Werten und Laufzeitparametern sowie
   einen Commit und ein Git-Tag. Qwen bewertet danach, ob der Punkt pausiert,
   weiter verbessert oder als Basis für eine neue Variante kopiert wird.

Qwen und Luna sollen neue Forschungskandidaten in diesem Dokument eintragen und
den vorgeschlagenen Runner-Eintrag beschreiben. Der Supervisor übernimmt einen
Kandidaten erst in einen Matrixlauf, wenn Branch, Worktree und reproduzierbare
Startparameter vorhanden sind.

## Agenten-Kontext-Watchdog

`scripts/agent-context-watchdog.sh` misst globalen KV-Füllgrad, freie Slots,
Prefill-Reserve, laufende/wartende Requests und aktive OpenCode-Prozesse. Der
Timer wird mit `scripts/install-agent-context-watchdog.sh` installiert und
schreibt `state/agent-context/latest.txt` sowie bei Druck `state/agent-context/pressure`.

Die Rollenlimits sind absichtlich noch nicht aktiv: Erst wenn Agenten ihre Rolle,
ID und ihr Kontextlimit als Request-Metadaten melden, kann der Watchdog den
relativen Füllgrad berechnen und gezielt den Agenten mit dem höchsten Füllgrad
zum Compacting auffordern. Bis dahin warnt er nur und lässt laufende Arbeit
unangetastet.
