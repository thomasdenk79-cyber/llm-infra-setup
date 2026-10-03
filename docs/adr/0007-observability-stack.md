# ADR 0007: Prometheus, Grafana und Loki

- Status: Akzeptiert, 2026-10-02 ergaenzt
- Kontext: Metriken und Protokollen muessen dauerhaft und nachvollziehbar bleiben,
  ohne Cloud-Dienst und ohne zusaetzliche Infrastruktur.
- Entscheidung: Prometheus/Grafana fuer Metriken, Loki/Alloy fuer Protokolle,
  Dozzle fuer den schnellen Blick. Host-Messgroessen ueber einen rootless
  Node-Exporter mit `/host`-Einhaengung (ADR 0010), eigene Host-Kennzahlen ueber
  eine Textdatei (ADR 0009). GPU-Messgroessen ueber nvidia-smi, DCGM nur optional.
- Folgen:
  * Vier eigene Dashboards, versioniert unter
    `config/monitoring/grafana/provisioning/dashboards/`, mit deutschen Titeln und
    menschenlesbaren Einheiten (Prozent, GiB, MB/s, ms).
  * Alarmregeln liegen als Prometheus-Regeln im Repository (`alerts.yml`) und sind
    ohne Grafana-Export pruefbar.
  * Gateway-Metriken sind zunoechst deaktiviert, weil das offizielle Bild keinen
    `/metrics`-Endpunkt mitliefert; der Weg zur spaeteren Freischaltung steht in
    `config/monitoring/prometheus.yml` und `docs/monitoring.md`.
  * Schwellenwerte bleiben bewusst grob, bis genuegend Messreihen vorliegen.
