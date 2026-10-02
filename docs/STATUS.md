# Projektstatus

Stand: 2026-10-02

## Done

- Host-Preflight erfasst CachyOS, Kernel, NVIDIA, Podman, CDI und ZFS.
- Vorhandenes Dataset `zpcachyos/llm/models` unter `/srv/llm/models` geprüft: `compression=zstd-9`, `recordsize=1M`, `atime=off`.
- Qwen3.8-Flash-Next-NVFP4 vollständig auf ZFS geladen und mit Index-/Safetensor-Prüfung verifiziert; die Hub-Revision steht in `versions.lock`.
- Pennyroyal v2.5.3 wurde für AMD64 gepullt; der Image-Digest ist in `versions.lock` gesperrt und die Quadlet bindet den API-Port nur an localhost.
- Die lokale Podman-Quadlet-Syntax wurde für CDI-Geräte auf `AddDevice=nvidia.com/gpu=all` angepasst.
- GPU-unabhängige Observability-Units können mit `make deploy-non-gpu` gestartet werden; Grafana erhält dabei ein externes rootless Podman-Secret.
- Rootless-Datenvolumes für Loki, Prometheus und Grafana werden mit `:U` für die jeweiligen Container-UIDs vorbereitet.
- PostgreSQL für LiteLLM wird mit `make deploy-non-gpu` samt lokalem 0600-Env-File und persistentem Volume gestartet.
- `make deploy-ready` ist als vollständiger Startpfad nach GPU-Reconnect/Reboot eingerichtet; Gateway, PostgreSQL und Pennyroyal teilen ein internes `llm-inference`-Netz.
- NVIDIA CDI und rootless Podman GPU-Smoke-Test erfolgreich ausgeführt.
- Pennyroyal, LiteLLM, PostgreSQL, Monitoring, Logging, Autossh und Komodo als versionierte Quadlet-Generatoren vorbereitet.
- `llmctl`, Healthcheck, Benchmark, Backup und Deployment-Orchestrierung vorhanden.
- MkDocs-Konfiguration, zweisprachige Einstiegsseiten und ADRs ergänzt.
- Service-Ports in Quadlets standardmäßig an localhost gebunden.

## Runtime status

Der Runtime-Container wurde noch nicht erfolgreich gestartet: Beim Baseline-Versuch war die eGPU aus `lspci` verschwunden, sodass `/dev/nvidia*` fehlte und CDI den Start korrekt ablehnte. PostgreSQL und Observability laufen; Gateway und Autossh warten auf die Runtime. API- und Pennyroyal-Metrikchecks bleiben deshalb offen.

## Todo

1. Pennyroyal-Quadlet deployen und Baseline-Requests prüfen, sobald die GPU wieder sichtbar ist.
2. ZFS-Snapshot für die verifizierte Modellrevision erstellen.
3. PostgreSQL/LiteLLM-Virtual-Key-Konfiguration mit lokalen Secrets testen.
4. Exporter, Prometheus Targets, Grafana Dashboards und Loki-Ingestion gegen den laufenden Stack verifizieren.
5. `make deploy-all`, `make healthcheck`, Benchmark und Reboot-Autostart testen.
6. KVM/libvirt als getrennte spätere Phase ergänzen.

## Betriebsregeln

- Keine ZFS-Pools erstellen, zerstören oder umstrukturieren.
- Dauerhafte Hoständerungen nur über Repository-Skripte.
- Geheimnisse bleiben außerhalb von Git.
