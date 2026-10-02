# ADR 0007: Prometheus, Grafana and Loki

- Status: Accepted
- Context: Metrics and logs need durable, queryable local storage.
- Decision: Use Prometheus/Grafana for metrics and Loki/Alloy plus Dozzle for logs.
- Consequences: Exporter metric names must be verified during runtime validation before final alert thresholds are enabled.
