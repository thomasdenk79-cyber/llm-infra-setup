# Performance-Messmatrix

Diese Matrix ist die Quelle der Wahrheit fuer die Sweep-Reihenfolge. Ein
Messpunkt gilt nur, wenn die Runtime vorher `healthy` ist und keine andere
GPU-Anwendung laeuft. Jeder Punkt speichert Ergebnis, echte `prompt_tokens`,
TTFT, steady Token/s, aggregierte Token/s, KV-Metriken, GPU-Werte und alle
Fehler aus systemd, Podman und Loki.

## Achsen

| Achse | Werte | Zweck |
|---|---|---|
| Profil | `baseline`, `sweet`, `c6-fp8-ram`, `maxkv`, `aggressiv`, `c16` | Runtime-/Speichervergleich |
| Kontextziel | 20k, 100k, 250k, 500k | Abfallkurve fuer Prefill, TTFT und Decode |
| Parallelitaet | 1, 2, 3, 4, 6, 8, 16 | Einzelrate, Batchrate und Admission-Limit |
| Wiederholung | mindestens 3 je Zelle | Median und Streuung statt Einzelzufall |
| Cachezustand | kalt, warm, identischer Prefix | SSD/Ple, Radix- und NIXL-Effekt trennen |
| PLE | NVMe, RAM nur bei ausreichendem RAM | SSD-Latenz gegen RAM-Bandbreite |
| HiCache | 0, 16, 32 GiB | Hostcache gegen freie RAM-Reserve |
| KV-Pool | automatisch, 824k, 1.0M | Kapazitaet gegen Decode-/VRAM-Kosten |
| ZFS-/Linux-Cache | Referenz, `primarycache=all`, ARC 8/16/24 GiB | PLE-Caching ohne RAM-PLE |
| Kernel/VM | Referenz, swappiness/cache-pressure/dirty ratios als Einzelarme | RAM-Druck und Flush-Verhalten |
| I/O/CPU | Scheduler, Readahead, Governor, NUMA/IRQ nur einzeln | SSD-Prefill und Decode-Jitter |

## Profile

* `baseline`: aktuelle qualifizierte Einstellungen ohne Online-FP8.
* `sweet`: vier grosse Sitzungen, hoher KV-Pool, Memory-Saver nur wenn mit dem
  Allocator kompatibel.
* `c6-fp8-ram`: offizieller Leistungspfad: Online-FP8, RAM-PLE, sechs Requests,
  36 Mamba-Slots, 1.048.576 angefordertes KV und Graphen bis Batch 6.
* `maxkv`: zwei Sitzungen, kleine Graphen, maximale gemeinsame KV-Flaeche.
* `aggressiv`: acht Sitzungen als Lastprofil.
* `c16`: Grenztest mit 16 Requests; nicht als produktiver Sweet Spot annehmen.

## Reihenfolge

1. Stabilitaet: Start, Ready-Zeit, zehn Minuten Leerlauf, Fehler-/OOM-Suche.
2. Baseline warm: 20k/100k/250k/500k bei C1, C2, C4.
3. Baseline parallel: 20k und 100k bei C6/C8.
4. `c6-fp8-ram`: dieselbe Matrix, nur wenn `MemAvailable` plus PLE-Reserve
   ausreicht; sonst automatisch ueberspringen.
5. `maxkv`, `aggressiv`, `c16`: KV-Kapazitaet, Admission, Fehlergrenze.
6. Cachearme Wiederholung: identischer Prefix warm, danach neue Suffixe.
7. Long-context soak: 250k und 500k mindestens drei Wiederholungen, danach
   erneuter Healthcheck und Loki-Fehlersuche.
8. Systemarme einzeln: ZFS-ARC, Linux-Page-Cache, VM-Parameter, NVMe-Readahead,
   I/O-Scheduler, CPU-Governor und NUMA/IRQ. Nach jedem Arm zur Referenz
   zurueckkehren, bevor der naechste beginnt.

## Abbruch- und Fehlerregeln

* OOM, `SIGTERM`, `SIGQUIT`, fehlender Ready-Endpunkt oder CUDA-Fehler markieren
  den Punkt als `failed`; der Runner geht erst nach sauberem Neustart weiter.
* Ein Profilwechsel ist ein eigener Messblock und kostet einen Kaltstart.
* RAM-PLE wird auf diesem Host mit etwa 15 GiB `MemAvailable` nicht automatisch
  aktiviert. Dafuer braucht es eine kontrollierte Vorpruefung oder weniger
  HiCache; NVMe-PLE bleibt die sichere Referenz.
* Das PLE-Zvol steht aktuell auf `primarycache=metadata` und
  `secondarycache=none`. `primarycache=all` wird als eigener ZFS-ARC-Arm
  untersucht, weil dann ARC und ext4-Page-Cache um denselben Speicher konkurrieren.
* Systemparameter werden zuerst nur aufgenommen (`sysctl -a`, ZFS- und
  Blockgeraetwerte). Eine Aenderung braucht ein idempotentes Skript, einen
  Checkpoint und einen Ruecklauf auf die gespeicherten Werte.
* KVM/QEMU und andere CUDA-Prozesse werden vor jedem Block protokolliert.

## Quellen und Vergleichswerte

Die offizielle Pennyroyal-Referenz meldet fuer Online-FP8 etwa 207 Token/s kurz,
196 bei 128k und 173 bei 490k; der offizielle C6-Pfad nutzt 36 Mamba-Slots und
1.048.576 angeforderte KV-Tokens. Diese Werte sind Vergleichspunkte, keine
Garantie fuer diesen Host.
