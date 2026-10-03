# Turbo-Upstream-PLE-Vergleich

Dieser Branch beschreibt einen isolierten Vergleichsdienst fuer das Turbo-r24-Rezept.
Das Startrezept bleibt gegenueber `config/turbo/serve-qwen38-flash-next-c6.sh`
unveraendert: TP1, Online-MXFP8, NEXTN, HiCache und CUDA-Graphs bleiben aktiv.
Die einzige Laufzeiterweiterung ist der PR36567-SSD-PLE-Reader (`io_uring`).

## Erzeugen und Starten

Im Haupt-Worktree zuerst das gepinnte Turbo-Image bauen:

```bash
make turbo-c6-install
```

Danach in diesem Branch die Vergleichs-Unit erzeugen. Sie verwendet Port `8003`
und den Container `sglang-turbo-upstream-ple`; laufende Dienste bleiben unberührt:

```bash
./scripts/52-install-sglang-turbo-upstream-ple.sh
systemctl --user daemon-reload
systemctl --user start sglang-turbo-upstream-ple.service
```

Logs und Bereitschaft:

```bash
journalctl --user -u sglang-turbo-upstream-ple.service -f
curl -fsS http://127.0.0.1:8003/health
```

## Vergleich

Gleiche Probe gegen beide Ports ausfuehren, zuerst C1, dann C6:

```bash
python3 scripts/benchmark_probe.py --base-url http://127.0.0.1:8003/v1 \
  --model Qwen3.8-Flash-Next --prompt 'Erklaere ZFS in einem kurzen Satz.' \
  --max-tokens 128 --sample-metrics
```

Im Startlog muessen diese Merkmale erscheinen:

```text
ple=file:/models/Qwen3.8-Flash-Next-NVFP4 ... io_uring
cuda graph: True
```

Wenn der Dienst beim Graph-Capture mit `dependency created on uncaptured work`
abbricht, ist das ein reproduzierbarer Fehler des SSD-PLE-/Graph-Vertrags. Der
Produktionsdienst wird dadurch nicht beeinflusst. In diesem Fall den Dienst stoppen:

```bash
systemctl --user stop sglang-turbo-upstream-ple.service
```

## Abgrenzung und Risiko

Der Vergleich benutzt dasselbe gepinnte Turbo-Image wie C6. Der Branch fuegt keine
neuen Modell- oder Speicherparameter hinzu und veraendert keine laufende Unit. Das
`io_uring`-Backend liest mit `O_DIRECT`; Page-Cache- oder mmap-Ergebnisse sind daher
nicht auf diesen Kandidaten uebertragbar. Der PR36567-Patch ist weiterhin ein
Overlay und kein unveraenderter SGLang-Mainline-Stand.
