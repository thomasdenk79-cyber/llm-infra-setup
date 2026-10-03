# Einordnung: why the throughput is where it is

Messungen vom 2026-10-02, Pennyroyal v2.5.3, Modell `Qwen3.8-Flash-Next-NVFP4`,
ThinkPad L15 Gen 2 (20X4) mit RTX PRO 6000 Blackwell ueber Thunderbolt.

## Ziel und Wirklichkeit

Erwartung war "ueber 200 Token/s pro einzelner Anfrage". Gemessen:

| Messung | Profil | gleichzeitige Anfragen | Vorlaufzeit | Schreibrate pro Anfrage | Gesamt durchsatz |
|---|---|---|---|---|---|
| 20261002T190438Z | normal | 1 | 1,51 s | **157,88 Token/s** | 121,88 Token/s |
| 20261002T190505Z | long | 1 | 3,60 s | **119,01 Token/s** | 90,29 Token/s |
| 20261002T190523Z | normal | 4 | 4,50 s | 91,73 Token/s | **242,47 Token/s** |

Die Zahl von 70 Token/s aus der alten Version dieses Repos war kein
Modellwert, sondern ein Messfehler: sie hat Vorlaufzeit und Schreibzeit
gemischt und zusaetzlich SSE-Chunks statt Token gezaehlt. Details unten.

## Die drei Zahlen nicht verwechseln

1. **Vorlaufzeit (time to first token).** Zeit bis zum ersten Zeichenn. Haengt am
   Einlesen des Prompts (Prefill) und am Aufwaermen.
2. **Schreibrate pro Anfrage (steady tokens/s).** Was der Nutzer beim Antworten
   sieht. Diese Zahl meint "200 Token/s pro einzelner Anfrage".
3. **Gesamtdurchsatz (aggregate tokens/s).** Alle gleichzeitigen Anfragen
   zusammen. Bei 4 Anfragen waren das 242 Token/s - die Karte kann also mehr als
   200, nur nicht fuer eine einzelne Anfrage.

Alte Messungen und manuelle Zaehlungen mit `curl -N` ueber Stream-Chunks sind
unbrauchbar: bei spekulativer Ausfuehrung steckt in einem Chunk mehr als ein
Token. Die neuen Skripte zaehlen deshalb die von der API gemeldeten
`usage.completion_tokens`.

## Warum eine einzelne Anfrage nicht ueber ~160 Token/s kommt

Die GPU selbst ist nicht das Limit. Waehrend der Messung:

```
GPU-Auslastung 61 %, Leistungsverbrauch 275 W (Limit 300 W), VRAM 94.913 MiB / 97.887 MiB
```

61 % Auslastung bei 275 W heisst: die Rechenwerke warten. Die Ursache ist der
Datenweg zum Arbeitsspeicher des Rechners.

### 1. PCIe-Anbindung: reale Eigenschaft, aber NICHT die Grenze (Korrektur 2026-10-03)

Die erste Fassung dieses Textes hielt die schmale Anbindung fuer die Hauptursache.
Nachgemessen ist das falsch. Waehrend des Schreibens gemessen mit
`nvidia-smi dmon -s t`:

```
PCIe-Durchsatz:  3 bis 25 MB/s (Ein- und Ausgabe)
GPU-Auslastung:  61 %      Verbrauch: 275 W von 600 W Limit
Temperatur:      56 C      Takt: 2857 MHz von 3090 MHz moeglich
```

Die Strecke ist also praktisch leer - das Modell und seine Puffer liegen komplett
in der Grafikkarte, ueber die Bruecke gehen nur Prompteingabe, Ergebnisausgabe und
die Auszuege der ausgelagerten Einbettungstabellen. Die Anbindung Erklaert daher
nicht, warum eine einzelne Anfrage bei rund 160 Token/s aufhoert.

Anbindung ist trotzdem interessant: sobald die Tabellen nicht mehr im Seiten-
speicher stehen, muss der Host sie nachliefern, und dann zaehlt jede Millisekunde
auf dem Weg. Pruefen:

```bash
cat /sys/bus/pci/devices/0000:22:00.0/current_link_speed /sys/bus/pci/devices/0000:22:00.0/current_link_width
./scripts/ple-preload.sh --status        # liegt die Tabelle im RAM?
nvidia-smi dmon -s t -c 20               # PCIe-Durchsatz bei Last
```

### 2. SSD-Auslagerung der Einbettungen (PLE) auf einer Loop-Datei in ZFS

Standardbetauung ist `PENNY_PLE_BACKEND=nvme`; die Tabelle liegt in einer
110-GiB-ext4-Datei auf dem ZFS-Pool. Jeder Schritt, der eine Zeile nachlaedt,
geht damit durch drei Schichten: Loop -> ext4 -> ZFS -> NVMe-Treiber. Zusaetzlich
verweigert ZFS den direkten `io_uring`-Lesepfad (`os error 38`), weshalb ueberhaupt
ext4 noetig war. Das kostet Latenz pro Token.

Wege, das zu verbessern (in dieser Reihenfolge):

* **Echte Partition statt Loop-Datei.** Freie NVMe-Partition anlegen und
  `PLE_BLOCK_DEVICE=/dev/nvme1n1p1` in `config/host.env` setzen;
  `make ple-nvme` kummert sich um Rest. Keine Umformatierung bestehender
  Partitionen - das Skript bricht ab und sagt, was zu tun ist.
* **RAM-Rueckschau (HiCache) auf dem grossen Rechner.** Auf dem 64-GiB-L15 ist
  `PENNY_HICACHE_SIZE_GB=0` gesetzt, sonst verdrängt der Lader den Platz, den
  das Modell braucht (siehe Abschnitt Arbeitsspeicher). Auf einem Rechner mit
  192 GiB RAM kann 32 oder 64 gesetzt werden.

### 3. Vorhersage (spekulative Ausfuehrung)

Die Runtime nutzt NEXTN mit 3 Schritten, topk 1, 4 Entwurf-Token. Akzeptiert sie
3,2 Token pro Schritt, ist das fast der moegliche Maximalgewinn; sinkt die
Akzeptanz (schwieriger Text, kalter Cache), faellt die Rate deutlich. Deshalb
zeigen Dashboard und Benchmark diese Zahl getrennt - sie erklaert Unterschiede
zwischen Messungen.

### 4. Arbeitsspeicher (HiCache)

Auf 64 GiB RAM fuehrt ein aktiver RAM-HiCache beim Modelladen zu Abbruch oder
Swap-Druck; messbar an `node_pressure_memory_stalled_seconds_total` und am
Swap-Panel. Der Wert 0 ist auf diesem Rechner die richtige Wahl, kein Fehler.

## Was 200 Token/s pro Anfrage realistisch machen wuerde

1. Direkte PCIe-x16-Anbindung (Desktop-Workstation oder Dock mit voller
   Anbindung statt Thunderbolt-Gehaeuse). Erwartbar: deutlicher Sprung, weil
   der Hauptbremskloetze entfalle.
2. PLE auf echter NVMe-Partition statt Loop-in-ZFS.
3. Kuehlung/Takt pruefen: `nvidia-smi -q -d PERFORMANCE` (Englisch) auf
   Throttle-Gruende; aktuell keine thermische Drosselung, aber knapp am
   Leistungslimit.

Nicht als Stellschraube empfohlen: `TP_SIZE=2`. Das teilt das Modell ueber zwei
GPUs und widerspricht der Grundregel, dass die Karte exklusiv dem Modell gehoert
(siehe `docs/adr/0013-*.md`); dazu waere dafuer eine zweite Karte noetig.



## Online-FP8: was der Schalter wirklich macht (und was nicht)

Der Auftragstext (§11) nennt "Online FP8" als Leistungsexperiment, und die
Versuchung liegt nahe, damit NVFP4 abzulösen. Das wäre ein Denkfehler. Aus dem
verwendeten Bild (`penny_config.py`, `qwen4_exp.py`, `sm120_online_fp8.py`) steht
der Zweck wörtlich da:

> `SGLANG_SM120_ONLINE_MXFP8` = "online FP8 **for FP4 checkpoints**"

Und aus dem Modellcode (`convert_eligible_linears_to_mxfp8`):

> "eligible BF16 linears use MXFP8; HyperConnection mix and lm_head use rowwise FP8"
> ausgeschlossen sind `FusedMoE` und `Qwen4ExpPLELayer`

Das heißt in Klartext:

| Teil des Modells | Format | Wirkung des Schalters |
|---|---|---|
| MoE-Experten (der große Teil der Gewichte) | **NVFP4** (Checkpoint, Blackwell-nativ) | bleibt - der Schalter fasst sie nicht an |
| noch in BF16 laufende dichte Projektionen, HyperConnection-Mix | BF16 | werden beim Laden in MXFP8/FP8 überführt |
| `lm_head` | BF16 | rowwise FP8 |
| PLE-Speicher und sein Projektionspfad | wie eingestellt (fp8-Tabelle) | bleibt, ausdrücklich ausgenommen |

NVFP4 bleibt also die Grundlage - genau weil Blackwell 4-Bit-Gewichte am besten
verarbeitet. Online-FP8 ergänzt nur die Schichten, die im FP4-Checkpoint gar
nicht quantisiert sind.

Warum es für diesen Rechner überhaupt interessant ist: die Messung zeigt eine zu
61 % ausgelastete Karte bei 275 W (Limit 600 W) und praktisch freier
PCIe-Strecke. Die wartenden Momente entstehen in den Rechen- und
Speicherpfaden der dichten Schichten und der Vorhersageprüfung, nicht bei den
Experten-GEMMs. Genau dort setzt Online-FP8 an.

Voraussetzungen und Grenzen (bei Verstoß bricht der Start hart ab):

* nur SM120 (RTX PRO 6000 Blackwell passt), CUDA nötig
* ein MXFP8-dichter Kernel muss verfügbar sein, sonst
  `RuntimeError: ... no MXFP8 dense kernel is available`
* kein gekoppelter `input`/`lm_head`-Gewichtssatz
  (`does not support tied input/lm_head weights`)
* **Nebenwirkung am Cache**: der Wert fließt in die NIXL-Cache-Identität ein
  (`--field online_mxfp8=...` im Startskript). Nach dem Umschalten ist der
  Zeichenspeicher-Cache neu aufzubauen - der erste Start dauert spürbar länger.

Einschalten (standardmäßig aus, weil Upstream sagt: erst Anleitung lesen):

```bash
PENNY_ONLINE_FP8=true make pennyroyal     # schreibt Environment= in die Unit
make apply-units                          # Unit installieren
```

oder im Tuning-Lauf als eigener Versuch:

```bash
./scripts/apply-tuning.sh --online-fp8
```

Der Lauf prüft nach dem Start die Logzeile "Flash-Next online FP8 enabled on SM120"
und vergleicht die Schreibrate. Fällt sie unter 90 % der Baseline, stellt das
Skript die alte Konfiguration wieder her.

**Erwartung ehrlich gesagt:** ein Gewinn auf die Schreibrate einer einzelnen
Anfrage ist möglich, aber nicht sicher - die dichten Schichten sind nur ein Teil
des Pfads. Der sichere Gewinn dieses Rechners liegt woanders: 8 statt 4
gleichzeitige Anfragen, mehr Zustandsslots und der Verzicht auf
`sleep-on-idle` (`docs/adr/0012-*.md`, ADR 0013).


## Wie viele Sitzungen gleichzeitig?

Zwei Grenzen, die leicht verwechselt werden (gemessen 2026-10-03):

```bash
curl -s http://127.0.0.1:8001/metrics | grep -E 'sglang:(context_len|max_total_num_tokens|kv_used_tokens|kv_available_tokens|kv_evictable_tokens|mamba_used_tokens|mamba_available_tokens)'
```

| Groesse | Wert | Bedeutung |
|---|---|---|
| `context_len` | 524288 | groesste einzelne Anfrage |
| `max_total_num_tokens` | 824384 | gemeinsamer Speicher fuer ALLE gleichzeitigen Anfragen |
| `mamba_used / available` | 8 / 2 | Plaetze fuer Zustandsscheiben (ungefaehr 10 Gespraeche) |

Praktisch:

* Eine Sitzung mit 300.000 Zeichennbeansprucht mehr als ein Drittel des
  gemeinsamen Speichers. **Zwei grosse Sitzungen** (je 250-300k) fuellen ihn fast
  ganz, **die dritte** verdraengt die anderen.
* Verdraengung ist nicht schlimm, aber teuer: Der Prompt muss erneut gelesen werden
  (Vorlaufzeit steigt sprunghaft), und `kv_available_tokens` naull heisst genau das.
* Deshalb: ab etwa 250-300k Kontext in einer Sitzung `compact` benutzen, oder dem
  Client einen Kontextgrenze geben (Vorlage dafuer:
  `~/.config/opencode/opencode.json.llm-infra`).
* Bei vielen kleinen Sitzungen ist die Plasma-Grenze die Zahl der
  Zustandsscheiben (um die 10), nicht der Speicher.

## Vorwärmen nach einem Neustart

Nach jedem Neustart ist der Seitenspeicher leer, und die erste Anfrage muss die
ausgelagerten Tabellen von der SSD holen. Das Vorladen dauert je nach
Tabellengroesse und Speicher ein bis zwei Minuten:

```bash
./scripts/ple-preload.sh              # einmal durchlesen
./scripts/ple-preload.sh --status     # Kontrolle: Anteil im Seitenspeicher
```

`make ple-warm` und `make ple-cache` sind dieselben Befehle.

## Richtig messen

```bash
./scripts/benchmark.sh              # quick, 1 Anfrage
./scripts/benchmark.sh normal 4     # 4 Anfragen gleichzeitig
MIN_TOKENS=150 ./scripts/benchmark.sh normal   # bricht bei zu niedrigem Wert ab
```

Vorbedingungen fuer eine saubere Zahl:

* keine anderen Anfragen (kein Chatfenster, kein `opencode`),
* Runtime ist warm (Log zeigt "ready to roll"),
* GPU-Dashboard hat keine Drosselung.

Das Skript wartet automatisch bis zu 60 Sekunden, wenn noch Anfragen laufen;
`BENCHMARK_ALLOW_BUSY=1` ueberspringt das (dann ist die Zahl kleiner, weil
geteilt wird). Ergebnisse liegen in `state/benchmarks/` (JSON, Markdown) und
in `state/benchmarks/history.csv` fuer den Vergleich ueber Wochen.

Die Metriken der Runtime liefern dieselbe Groesse kontinuierlich:
`sglang:gen_throughput` (Token/s ueber alle Anfragen),
`sglang:spec_accept_length`, `sglang:time_to_first_token_seconds`,
`sglang:inter_token_latency_seconds`. Dashboard "LLM-Betrieb" zeigt sie.

## Geaenderte Messgroessen im Vergleich zur alten Version

| frueher | heute | Grund |
|---|---|---|
| `tokens_per_second` (gemischt) | weiterhin geschrieben, zusaetzlich `steady_*`, `time_to_first_token_*`, `aggregate_*` | alte Verlaufswerte bleiben lesbar |
| Zaehlung ueber Stream-Chunks | `usage.completion_tokens` der API | Chunk != Token bei spekulativer Ausfuehrung |
| "concurrency" war eine Schleife | echte parallele Anfragen | Vergleichbarkeit |
| kein Aufwaermtest | erster Lauf zaehlt nicht | JIT/Warmup verfaelschte erste Messung |
