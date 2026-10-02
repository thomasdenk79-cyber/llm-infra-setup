# Projektstatus

Stand: 2026-10-02

## Done

- Host-Preflight erfasst CachyOS, Kernel, NVIDIA, Podman, CDI und ZFS.
- Das Modell-Dataset unter `/srv/llm/models` wird mit `compression=lz4`, `recordsize=1M` und `atime=off` betrieben. Das Dataset liegt auf dem vorhandenen `/srv`-Pool; Pools werden nicht automatisch erstellt oder verändert.
- Qwen3.8-Flash-Next-NVFP4 vollständig auf ZFS geladen und mit Index-/Safetensor-Prüfung verifiziert; die Hub-Revision steht in `versions.lock`.
- Pennyroyal v2.5.3 wurde für AMD64 gepullt; der Image-Digest ist in `versions.lock` gesperrt und die Quadlet bindet den API-Port nur an localhost.
- Die lokale Podman-Quadlet-Syntax wurde für CDI-Geräte auf `AddDevice=nvidia.com/gpu=all` angepasst.
- GPU-unabhängige Observability-Units können mit `make deploy-non-gpu` gestartet werden; Grafana erhält dabei ein externes rootless Podman-Secret.
- Rootless-Datenvolumes für Loki, Prometheus und Grafana werden mit `:U` für die jeweiligen Container-UIDs vorbereitet.
- PostgreSQL für LiteLLM wird mit `make deploy-non-gpu` samt lokalem 0600-Env-File und persistentem Volume gestartet.
- Homepage ist als zentrale Einstiegsseite unter Port 3002 vorbereitet; Open WebUI für Chat, Datei-Upload und RAG läuft unter Port 3001.
- LiteLLM und Open WebUI können ohne GPU gestartet werden; Modellanfragen warten bis Pennyroyal wieder verfügbar ist.
- `make deploy-ready` ist als vollständiger Startpfad nach GPU-Reconnect/Reboot eingerichtet; Gateway, PostgreSQL und Pennyroyal teilen ein internes `llm-inference`-Netz.
- NVIDIA CDI und rootless Podman GPU-Smoke-Test erfolgreich ausgeführt.
- Pennyroyal, LiteLLM, PostgreSQL, Monitoring, Logging, Autossh und Komodo als versionierte Quadlet-Generatoren vorbereitet.
- `llmctl`, Healthcheck, Benchmark, Backup und Deployment-Orchestrierung vorhanden.
- MkDocs-Konfiguration, zweisprachige Einstiegsseiten und ADRs ergänzt.
- Service-Ports in Quadlets standardmäßig an localhost gebunden.

## Runtime status

Der Runtime-Container läuft auf dem 64-GB-L15 mit vorbereitetem NVMe-PLE-Overlay auf einem ext4-Loop-Image (`/srv/llm/ple-ext4/Qwen3.8-Flash-Next-PLE-NVME`, etwa 48 GB), `PENNY_PLE_BACKEND=nvme` und `PENNY_HICACHE_SIZE_GB=0`. Der ZFS-Pfad lieferte beim SSD-Reader `OSError: Function not implemented (os error 38)`; der ext4-Testpfad mit `PodmanArgs=--security-opt=seccomp=unconfined` startet erfolgreich. Am 2026-10-02 meldete Pennyroyal `Application startup complete`, `The server is fired up and ready to roll!` und die Smoke-Anfrage erhielt HTTP 200. Der Start benötigt etwa 15 Minuten, davon 154 s Gewichte laden und danach Autotuning/CUDA-Graph-Aufwärmung. Das Setup erzeugt das Overlay idempotent und überspringt es bei vorhandenem Index/PLE-Tisch.
- Der ZFS ARC wird über `ZFS_ARC_MAX_GB=16` begrenzt, damit der Host bei der Modellinitialisierung nicht durch ARC-Cache verdrängt wird. Das ext4-Image wird von `scripts/47-setup-ple-storage.sh` als `nofail`-Loop-Mount in `/etc/fstab` eingetragen.

## Todo

### Später: professionelle Verwaltung

- Cockpit oder Podman Desktop als WebGUI bewerten.
- Komodo als GitOps-Steuerung aktivieren.
- Rollen, Deployments, Monitoring und Serviceübersicht wie bei einer kleinen
  OpenShift-ähnlichen Plattform ergänzen.

1. Host neu starten und prüfen, dass eGPU, `/dev/nvidia*` und NVIDIA-CDI wieder sichtbar sind.
2. Pennyroyal-Quadlet deployen und Baseline-Requests prüfen, sobald die GPU wieder sichtbar ist.
3. ZFS-Snapshot für die verifizierte Modellrevision erstellen.
4. PostgreSQL/LiteLLM-Virtual-Key-Konfiguration mit lokalen Secrets testen.
5. Exporter, Prometheus Targets, Grafana Dashboards und Loki-Ingestion gegen den laufenden Stack verifizieren.
6. `make deploy-all`, `make healthcheck`, Benchmark und Reboot-Autostart testen.
7. KVM/libvirt als getrennte spätere Phase ergänzen.
8. NVMe-PLE auf einer echten dedizierten ext4/NVMe-Partition testen und den Loop-Image-Overhead messen. Danach Speicher-/Durchsatzvergleich gegen RAM-PLE; Upstream dokumentiert rund 47.7 GiB RAM-Ersparnis bei zusätzlicher SSD-I/O-Latenz.

## Ein-Befehl-Setup

`./scripts/setup-qwen-pennyroyal.sh` bündelt ZFS-Pfad, Paket-/GPU-Prüfung,
Modell-Download, Pennyroyal-Quadlet, Deployment und Healthcheck. Variablen wie
`ZFS_POOL`, `AUTO_REBOOT`, `DOWNLOAD_MODEL` und `START_RUNTIME` können vor dem
Aufruf gesetzt werden.

## Betriebsregeln

- Keine ZFS-Pools erstellen, zerstören oder umstrukturieren.
- Dauerhafte Hoständerungen nur über Repository-Skripte.
- Geheimnisse bleiben außerhalb von Git.
