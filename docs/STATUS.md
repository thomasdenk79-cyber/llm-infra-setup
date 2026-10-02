# Projektstatus

Stand: 2026-10-02

## Done

- Host-Preflight erfasst CachyOS, Kernel, NVIDIA, Podman, CDI und ZFS.
- Vorhandenes Dataset `zpcachyos/llm/models` unter `/srv/llm/models` geprüft: `compression=zstd-9`, `recordsize=1M`, `atime=off`.
- NVIDIA CDI und rootless Podman GPU-Smoke-Test erfolgreich ausgeführt.
- Pennyroyal, LiteLLM, PostgreSQL, Monitoring, Logging, Autossh und Komodo als versionierte Quadlet-Generatoren vorbereitet.
- `llmctl`, Healthcheck, Benchmark, Backup und Deployment-Orchestrierung vorhanden.
- MkDocs-Konfiguration, zweisprachige Einstiegsseiten und ADRs ergänzt.
- Service-Ports in Quadlets standardmäßig an localhost gebunden.

## Runtime status

Der Hugging-Face-Download wurde gestartet und ist resumierbar. Der Runtime-Container, PostgreSQL, Gateway und Observability wurden noch nicht gestartet. Deshalb sind API-, Grafana- und Prometheus-End-to-End-Checks noch offen.

## Todo

1. Modelldownload vollständig abschließen und Revision/Dateiprüfung in `versions.lock` eintragen.
2. Pennyroyal-Image-Digest erfassen, Quadlet erzeugen und Baseline-Requests prüfen.
3. PostgreSQL/LiteLLM-Virtual-Key-Konfiguration mit lokalen Secrets testen.
4. Exporter, Prometheus Targets, Grafana Dashboards und Loki-Ingestion gegen den laufenden Stack verifizieren.
5. `make deploy-all`, `make healthcheck`, Benchmark und Reboot-Autostart testen.
6. KVM/libvirt als getrennte spätere Phase ergänzen.

## Betriebsregeln

- Keine ZFS-Pools erstellen, zerstören oder umstrukturieren.
- Dauerhafte Hoständerungen nur über Repository-Skripte.
- Geheimnisse bleiben außerhalb von Git.
