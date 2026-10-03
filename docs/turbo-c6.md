# Separater SM120-Turbo-C6-Dienst

Der Branch `turbo-c6-production` baut den Stand `mratsim/sglang-qwen38fn-sm120-turbo`
Revision `c6cd5062669625fdbaf08032931f10b6661f8f6f` als eigenes lokales Image
`localhost/sglang-qwen38fn-sm120-turbo:r24`. Pennyroyal bleibt als Fallback auf
Port 8001 erhalten; Turbo verwendet Port 8002 und den Container
`sglang-turbo-c6`.

## Produktionswerte

* TP1, RadixArk Qwen3.8 Flash-Next NVFP4, Kontext 262144 (Turbo-Qualifikation)
* C6: sechs Requests, `extra_buffer_lazy`, 27 Mamba-Slots (`4*C+3`)
* Online-MXFP8, FP8-KV, NEXTN/MTP 3/1/4, `gdn-mtp-cache-mode=none`
* `mem_fraction_static=0.98`, Page-Size 64, Chunked Prefill 4096
* 8 GB HiCache; der übrige Host-RAM bleibt reclaimable für Linux/ZFS ARC
* NVMe-PLE über den vorhandenen Overlay unter `/srv/llm/ple-native/...`, kein
  gepinntes RAM-PLE

Das Turbo-Image enthält seine eigenen SM120-, Online-FP8-, RecoverSSM- und
MTP-Patches. Die NVMe-PLE-Anbindung nutzt ausschließlich die vorhandene
Datei-Backend-Schnittstelle (`--ple-offload-backend file`); Pennyroyal-Patches
werden nicht in den Compute-Stack kopiert.

## Bauen und Smoke-Test

```bash
make turbo-c6-install       # Quellstand holen, Image bauen, Quadlet erzeugen
make turbo-c6                # separaten Dienst starten
curl -fsS http://127.0.0.1:8002/health
systemctl --user status sglang-turbo-c6.service
podman logs sglang-turbo-c6
```

Vor dem Start muss das vorhandene Overlay geprüft werden:
`make verify-ple`. Ein fehlendes Overlay wird mit `make ple-nvme` erzeugt.
Es werden keine Benchmarks oder Profilvergleiche durch diesen Installationspfad
ausgeführt. Für den Smoke-Test sind sechs kurze parallele Requests zulässig;
bei CUDA-OOM, Swap-Nutzung oder fehlendem Health-Status bleibt Pennyroyal der
Rückfall.

## Smoke-Ergebnis 2026-10-03

Der Turbo-Start hat Modell und Laufzeitparameter korrekt erkannt (TP1, C6, 27
Mamba-Slots, Online-MXFP8, FP8-KV, NEXTN/MTP, 8 GiB HiCache). Der Start stoppt
jedoch beim NVMe-PLE: Turbo r24s `--ple-offload-backend file` verweigert die
RTX PRO 6000, weil diese GPU keine pageable Host-Table-Zugriffe ueber Unified
Memory unterstuetzt. Der Fehler ist somit eine dokumentierte Runtime-Grenze,
kein CUDA-OOM. Das Service bleibt gestoppt, damit kein Restart-Loop entsteht.

Die vorhandene Pennyroyal-NVMe-Implementierung ist ein separater, versions- und
Hash-gepruefter SSD-Stream-Hook. Sie kann nicht ohne weitere Portierung in Turbo
r24 geladen werden; ein blindes Deaktivieren der Hash-Pruefung wuerde Turbo- und
Penny-PLE-Patches doppelt bzw. unqualifiziert kombinieren. Fuer den gewuenschten
Sweet-Spot muss daher entweder der SSD-Stream-Hook gegen Turbo r24 portiert und
qualifiziert werden oder Turbo voruebergehend mit gepinntem RAM-PLE auf einem Host
mit ausreichend RAM laufen.
