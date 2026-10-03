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
* `maxkv`: vorlaeufig eine Sitzung, Graph-Maximum 1 und grosse VRAM-Reserve;
  erst nach einem stabilen Lauf wieder auf mehrere Sitzungen erweitern.

## Externe Zielpunkte fuer die eigene Sweep-Reihe

Die offiziellen Pennyroyal-Daten nennen fuer Flash-Next auf einer RTX PRO 6000
mit 524.288 Kontext, HiCache/NIXL und FR-Spec **C=6** sowie einen beobachteten
KV-Pool von **1.039.040 Tokens**. Online-FP8 gewann in der offiziellen Messung
etwa 3,86 GiB VRAM und steigerte C1 von 161,47 auf 207,12 Token/s; bei 490K
Kontext blieben 172,64 Token/s uebrig. Diese Werte sind Ziel- und
Vergleichspunkte, keine Garantie fuer unsere NVMe-PLE-Variante.

Weitere reproduzierbare Community-Punkte:

* `gabrielolympie`: interaktives C4-Profil mit etwa 572K KV und 231 Token/s C1;
  grosses Einzelprofil mit etwa 827K KV und 185 Token/s C1; optional C8 mit
  758 Token/s aggregiert. Das C8-Profil verlangt etwa sechs Mamba-Slots je
  laufender Anfrage. Relaxte MTP-Annahme ist fuer lossless Vergleiche auf 1.0
  zu setzen.
* `keplerzip`: `mem_fraction=0.975`, nativer 256K-Kontext, C8, 32 Mamba-
  Slots, 282.432 KV und 632,4 Token/s aggregiert. Das ist ein stabiler
  Durchsatzpunkt, aber kein 524K/1M-KV-Profil.

Daraus folgt die Messleiter: erst stabiler C1-Basispunkt, dann Online-FP8,
dann C4/C6 mit Slots etwa 6x der Requests, danach C8. Jede Stufe braucht
Wiederholungen mit kurzer, mittlerer und langer Eingabe sowie einen 24h-Soak;
die offiziellen Zahlen wurden nicht mit einem einzelnen erfolgreichen Start,
sondern mit validierten Arbeitslasten ermittelt.
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

## System- und Kernelarme

| Arm | Aenderung | Aussage, die wir ableiten wollen |
|---|---|---|
| K0 | aktueller CachyOS-Kernel, Scheduler unveraendert | Referenz fuer alle Modellmessungen |
| K1 | gleicher Kernel, Governor `performance` | CPU-/PLE-Latenz gegen `powersave` |
| K2 | BORE, falls im Kernel verfuegbar | Interaktive Einzelantworten und Jitter |
| K3 | eigener BORE-Kernel mit gleicher Konfiguration | Effekt des Kernels getrennt vom Userspace |
| K4 | `schedutil`/Standard gegen BORE bei C1/C4/C8 | Scheduler-Skalierung unter Last |
| V1 | ZFS `primarycache=metadata` | NVMe-Referenz ohne Daten-ARC |
| V2 | ZFS `primarycache=all`, ARC 8/16/24 GiB | PLE aus ARC/Page-Cache, RAM-Konkurrenz |
| V3 | Linux `vm.swappiness`, `vfs_cache_pressure`, dirty ratios | Swap-/Flush-Verhalten und Long-Prefill |
| I1 | NVMe-Readahead und I/O-Scheduler einzeln | PLE-Prefill und SSD-Wartezeit |
| N1 | NUMA-/IRQ-Bindung unveraendert | Referenz ohne CPU-Affinitatsannahmen |
| N2 | kontrollierte CPU-/IRQ-Bindung | PLE-Reader- und Tokenizer-Jitter |

Jeder Arm wird mit derselben Runtime-Konfiguration in mindestens drei
Wiederholungen gemessen. Wir speichern Median, P05/P95, Standardabweichung,
Fehlerquote und Start-/Ready-Zeit. Ein Arm gilt erst als besser, wenn er bei
identischem Kontext und gleicher Parallelitaet mindestens zwei der drei
Wiederholungen verbessert, ohne Qualitaets- oder Stabilitaetsfehler.

## Ableitungen

* Steigt C1, aber nicht C4/C8, ist der Gewinn wahrscheinlich CPU-/Latenzpfad;
  steigt nur C4/C8, ist es eher Batch-Scheduling oder GPU-Auslastung.
* Sinkt TTFT bei 250k/500k, aber nicht steady Token/s, verbessert der Arm nur
  Prefill/PLE. Steigt steady Token/s bei gleichem TTFT, verbessert er Decode.
* Steigt `kv_available_tokens` nach einem Cache-Arm, ohne dass VRAM knapp wird,
  ist der Arm fuer Kontextkapazitaet brauchbar; bei mehr Swap ist er verworfen.
* Mehr ARC kann den PLE-Reader beschleunigen, aber durch Doppelcache auch den
  Modellstart und den KV-Pool verschlechtern. Deshalb werden ARC-Hit, RAM,
  Swap, SSD-Lesevolumen und Runtime-Fehler gemeinsam bewertet.
* Ein Scheduler-/Kernelgewinn muss unter identischer GPU-, PLE- und
  Cachekonfiguration reproduzierbar sein; ein einzelner schneller Lauf zaehlt
  nicht als Beleg.
