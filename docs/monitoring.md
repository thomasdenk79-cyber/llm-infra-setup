# Monitoring

Prometheus, Grafana, Loki und Alloy werden als rootless Quadlets vorbereitet. Die Konfiguration liegt unter `config/monitoring/`; Zustandsdaten liegen außerhalb des Repositories unter `~/.local/share/llm-infra`.

Vor dem Start ein lokales Podman-Secret `grafana_admin_password` anlegen. Das Dashboard `LLM - Qwen3.8 Flash-Next / Pennyroyal` wird aus `config/monitoring/grafana/provisioning/dashboards/` automatisch geladen. Während die GPU-Runtime pausiert ist, zeigen Pennyroyal-Panels `DOWN`; Prometheus-, Host- und Stack-Metriken funktionieren unabhängig davon.
