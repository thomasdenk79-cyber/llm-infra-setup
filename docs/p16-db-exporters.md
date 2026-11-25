# P16 LAB-DB-Metriken in diesem Stack

Dieser Stack bleibt die Source of Truth für Prometheus, Grafana, Loki und
Alloy. Auf dem P16 (CachyOS) läuft **kein zweiter Stack**, nur drei leichte
Collector-Units:

| Unit | Port | Inhalt |
|---|---|---|
| `db-node-exporter.service` | 9100 | Host-/Dateisystemmetriken |
| `db-postgres-exporter.service` | 9187 | PostgreSQL 19 `edilab` |
| `db-oracle-exporter.service` | 9161 | Oracle 21c `EDILAB` |

Implementation, Secrets und `just`-Rezepte liegen im Gegenstück
`ora2pg-cachyos-infra-setup`:

```bash
cd /home/z000g9hu/srv/edi-repos/ora2pg-cachyos-infra-setup
just db-exporters-plan
just db-exporters-apply
```

Die Ports 9100/9187/9161 sind in der P16-UFW ausschließlich für
`192.168.0.198` (t15) geöffnet. scrape_configs stehen in
`config/monitoring/prometheus.yml` (`p16-node`, `p16-postgres`, `p16-oracle`).
