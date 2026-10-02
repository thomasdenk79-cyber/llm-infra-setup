# Monitoring

Prometheus, Grafana, Loki und Alloy werden als rootless Quadlets vorbereitet. Die Konfiguration liegt unter `config/monitoring/`; Zustandsdaten liegen außerhalb des Repositories unter `~/.local/share/llm-infra`.

Vor dem Start ein lokales Podman-Secret `grafana_admin_password` anlegen. Dashboards und Alert-Regeln werden als Code ergänzt, sobald die echten Exporter-Metriknamen nach dem Baseline-Start verifiziert sind.
