# Pennyroyal SSD Stream Variante

Dieser Branch hält eine testbare Pennyroyal-Variante mit dem im Image
enthaltenen `sglang-ssd-stream`-Plugin fest. Die Runtime bleibt das gepinnte
Pennyroyal-v2.5.3-Image; geändert wird nur die bisher fehlende gemeinsame
`ple-backend.sh`-Datei und deren Quadlet-Mount.

## Auswahl

```bash
PENNY_PLE_BACKEND=nvme \
PENNY_PLE_NVME_MODEL=/srv/llm/ple-native/Qwen3.8-Flash-Next-PLE-NVME \
./scripts/50-install-pennyroyal.sh
```

Danach muss die Variante kontrolliert angewendet und gestartet werden:

```bash
./scripts/apply-runtime-unit.sh --list
./scripts/apply-runtime-unit.sh --unit pennyroyal --restart
```

Der NVMe-Zweig setzt ausschließlich `SGLANG_PLUGINS=ssd_stream`. Das Plugin
liest mit einem kleinen, ausgerichteten `io_uring`-Pool und staged die Zeilen
vor dem Decode. Seine Graph-Hooks bereiten die SSD-Arbeit außerhalb des
Captures vor und synchronisieren beim Replay über CUDA-Events. Deshalb bleiben
Decode-CUDA-Graphs aktiv; CPU-Offload oder ein zusätzlicher Plugin-Mix wird
bewusst abgelehnt.

Die Tabelle muss ein geprüftes SSD-Stream-Manifest enthalten. Der Start bricht
bei fehlendem Plugin, falschem Manifest oder beschädigten Shards ab. Die
Variante verändert keine laufenden Units, ZFS-Datasets oder Modelldateien und
kann durch Rücksetzen von `PENNY_PLE_BACKEND=ram` auf den normalen Pennyroyal-
Pfad zurückgestellt werden.

## Erwarteter Vergleich

Der RAM-Pfad bleibt die Referenz mit maximaler Latenzreserve. SSD Stream spart
die rund 47,68 GiB dauerhaft belegten Host-RAM, verwendet aber SSD-I/O und
kann bei zufälligen PLE-Zeilen langsamer sein. Im Unterschied zum aktuellen
Turbo-Overlay ist der Plugin-Graph-Hook für CUDA-Graph-Replay vorgesehen;
gemessen werden müssen C1 und C6 mit identischem Prompt, Kontext und
`max_tokens`.
