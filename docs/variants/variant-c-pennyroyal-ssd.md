# Variante C: Pennyroyal mit eingebautem SSD-Stream-Plugin

* Branch: `pennyroyal-plugin-variant`
* Worktree: `~/work/llm-infra-setup-pennyroyal`
* Ausgangscommit: `1273262` (turbo-c6-production), Basis Pennyroyal v2.5.3
  (`ghcr.io/jpezzulli/sglang-rtxpro6000:v2.5.3`, Digest in `versions.lock`)
* Kein eigenes Bild: das gepinnte Pennyroyal-Bild bleibt unveraendert.

## Idee

Pennyroyal bringt fuer diesen Modellzweig bereits einen offiziellen SSD-PLE-Pfad
mit: das Bild-Plugin `sglang_ssd_stream` (io_uring-Reader, Staging vor dem
Decode, Graph-Hooks, die die SSD-Arbeit ausserhalb des Captures vorbereiten
und im Replay ueber CUDA-Events synchronisieren). Diese Variante nutzt genau
denselben, von SGLang/Pennyroyal gepflegten Pfad statt des eigenen
PR36567-/Turbo-Readers und haelt damit Decode-CUDA-Graphen aktiv.

Turbo-spezifische Patches (eigener ThreadPool, eigene Events, eigenes
`qwen4_ple_nvme.py`) werden bewusst NICHT uebernommen.

## Was der Branch aendert (Konfiguration, kein Code im Bild)

* `config/pennyroyal/ple-backend.sh` (neu): die gemeinsame Auswahldatei,
  die das Laufzeit-Rezept an Zeile 176 einbindet. Sie fuehrt
  `PENNY_PLE_BACKEND=ram|nvme`, prueft Manifest und Plugin, exportiert
  `SGLANG_PLUGINS=ssd_stream` und die NAMESPACE-Felder
  (`ple_backend`, `ple_manifest_sha256`, `ple_reader_version`).
* `quadlet/pennyroyal.container` (vom Generator 50 erzeugt): Mount der
  Auswahldatei nach `/opt/pennyroyal/configs/pennyroyal/ple-backend.sh`,
  Umgebungsvariablen `PENNY_PLE_BACKEND=nvme`,
  `PENNY_PLE_NVME_MODEL=/ple/Qwen3.8-Flash-Next-PLE-NVME`, C6-Kennzahlen
  (6 Anfragen, 36 Mamba-Slots, HiCache 16, Graph-Max 6, Online-FP8 true).
* `scripts/50-install-pennyroyal.sh`: Defaults fuer die obigen Werte, damit
  ein frischer Auscheck dieselbe Unit erzeugt (`make drift` prueft das).

## CUDA-Operationen und CPU-/SSD-Arbeit

Verantwortung liegt beim Bild-Plugin, nicht in diesem Repository:

* Waehrend Capture: keine CPU-/SSD-Arbeit (Plugin-Hooks verschieben sie vor
  das Capture), Synchronisation im Replay ueber CUDA-Events.
* Der Start bricht ab, wenn Plugin, Manifest oder Shards fehlen - kein
  stiller Rueckfall in einen anderen Pfad.

Voraussetzung ist, dass das Bild die SSD-Stream-Komponenten
(`.ple-nvme/sglang_ssd_stream/plugin.py`,
`scripts/pennyroyal/check_ple_nvme.py`) mitbringt; andernfalls bricht
`ple-backend.sh` mit klarer Meldung ab (dokumentierter Erwartungswert des
Bildes, im Moment nicht nachgeprueft, weil der Bildinhalt hier nicht
geoeffnet wurde).

## Start (spaeter, manuell; GPU exclusiv)

```bash
cd ~/work/llm-infra-setup-pennyroyal
PENNY_PLE_BACKEND=nvme \
PENNY_PLE_NVME_MODEL=/srv/llm/ple-native/Qwen3.8-Flash-Next-PLE-NVME \
  ./scripts/50-install-pennyroyal.sh
./scripts/apply-runtime-unit.sh --list
# Produktions-Turbo stoppen, dann Pennyroyal kontrolliert neu starten:
systemctl --user stop sglang-turbo-c6.service
./scripts/apply-runtime-unit.sh --unit pennyroyal --restart
curl -fsS http://127.0.0.1:8001/health
```

## Stop/Rueckbau

```bash
PENNY_PLE_BACKEND=ram ./scripts/50-install-pennyroyal.sh
./scripts/apply-runtime-unit.sh --unit pennyroyal --restart   # oder Penny stoppen
systemctl --user start sglang-turbo-c6.service                # Turbo zurueck
```

## Messen

`./scripts/benchmark.sh quick 1` und `quick 6` gegen Port 8001 (Standard des
Skripts); Vorlauf-, Schreib- und Gesamtrate getrennt protokollieren
(`state/benchmarks/history.csv`).

## Risiken / offene Punkte

* Bildinhalt (Plugin + Pruefskript) ist nicht verifiziert; Scheitern ist ein
  gueltiges Testergebnis dieser Variante.
* NIXL-/HiCache-Identitaet: Wechsel von `ple_backend` baut den
  Zeichenspeicher-Cache neu auf (siehe `docs/performance.md`).
* Kein Live-Test, kein Benchmark durchgefuehrt.

## Fehleranalyse und Reparatur (2026-10-04)

Der Lauf `20261004T040547Z` ist nicht beim Start oder CUDA-Graph-Capture
abgebrochen: Das SSD-Stream-Plugin meldete die geladene 47,68-GiB-Tabelle,
Target-Verify- und Draft-Decode-/Extend-Graphs wurden aufgenommen, die Runtime
wurde bereit und Chat-Anfragen liefen erfolgreich. Der erste Quick-Benchmark
hatte 0 Fehler. Der zweite Benchmark brach mit `printf: ... broken pipe` ab,
weil die Busy-Pruefung in `scripts/benchmark.sh` `awk` nach dem ersten
Prometheus-Treffer beendete. Durch `set -o pipefail` wurde der dadurch
abgebrochene `curl`-Schreibvorgang zum Skriptfehler. Der Matrix-Runner meldete
deshalb `benchmark_failed` und startete den Heiler; die Evidenz enthaelt keinen
Runtime-Crash.

Der minimale Patch liest die Metrik-Antwort vollstaendig ein und druckt den
letzten Wert erst in `END`. So kann `curl` die Antwort vollstaendig schreiben.
Es wurden keine Runtime-Units und keine PLE-/Graph-Einstellungen geaendert.
Der Lauf belegt weiter, dass multimodales Prefill ohne Graph ausgefuehrt wird,
waehrend Decode-CUDA-Graphs aktiv bleiben. Der Hinweis auf 524288 angeforderten
gegen 262144 abgeleiteten Kontext ist ein separates Genauigkeits-/CUDA-Risiko;
dieser Patch qualifiziert den Kontext nicht neu.

Rest-Risiko: Die Busy-Pruefung wartet hoechstens 60 Sekunden und kann bei einer
echten haengenden Anfrage weiterhin messen oder fehlschlagen. Der minimale Patch
behebt den beobachteten Pipe-Fehler, aber der C6-Benchmark muss an einem
ruhigen Lauf erneut durch die vorgesehenen Gates gehen. Es wurde hier kein
Benchmark ausgefuehrt.
