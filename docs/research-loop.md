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

Qwen und Luna sollen neue Forschungskandidaten in diesem Dokument eintragen und
den vorgeschlagenen Runner-Eintrag beschreiben. Der Supervisor übernimmt einen
Kandidaten erst in einen Matrixlauf, wenn Branch, Worktree und reproduzierbare
Startparameter vorhanden sind.
