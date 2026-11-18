# Task: Grafana-Sichtbarkeit und Status-Seiten fuer den LLM-Stack (Demo)

Angelegt: 2026-11-18 (Betreiberanfrage). Status: in Arbeit.

## Ziel
1. Dashboards mit moderner, einheitlicher Visualisierung (Status-Ampeln, Einheiten,
   Schwellen, Legenden, Variablen, Drilldowns) - Best-Practice-Stand aus Community-
   Dashboards (node_exporter full, vLLM/SGLang-Monitoring-Vorlagen).
2. sgtop-Parallele: alle SGLang-Betriebskennzahlen in Grafana (Token usage,
   Throughput, Running/Queue, Cache, Speculative Decoding, Speicher, Scheduler).
3. KV-Cache-Anzeige klaeren und erweitern: 90-%-Wert ist der Pool inklusive
   evictable Radix-Cache-Tokens ((used+evictable)/max_total, gemessen 0.92);
   sgtop zeigt den effektiven Wert sglang:token_usage (gemessen 0.43). Beide
   Serien plus Verfuegbarkeit sichtbar machen, mit Erklaerung im Panel.
4. Explore/Logs: Loki-Datenquelle, Log-Panels je Container, Explore-Links.
5. Drei Status-Seiten in Grafana (ordnergleich, Demo am eigenen Stack, uebertragbar):
   a) 10-stack-status: Up/Down aller Dienste, Zeitachse wer/wann/warum down,
      Downtime-Schaetzung (ETA), Alarm史  (annotations).
   b) 11-incident-analyse: laufender Vorfall - Alarm -> KI-Agent (laeuft 914er
      Container, analysiert ueber das eigene Gateway) -> Befunde als Loki-Events,
      Tickets in SQLite via SQL, ETA aus Analyse. Externe Quellen (Splunk, Oracle,
      OpenShift, Nagios, Ticketsystem per MCP) sind dokumentierte Adapter-Stubs.
   c) 12-kunden-status: Service-Status fuer Kunden mit dynamischer Meldung
      (z.B. 'Stoerung erkannt und in Bearbeitung' -> 'OFTP-Ausgang: Ausfall,
      wiedervorhersagbar 30 min') und Zeitachse.

## Metrik-Vertrag (Kanalknoten: node-exporter-Textfile, job 'node')
llm_service_up{name}                       0|1
llm_service_info{name,state,reason,image}  1
llm_service_start_time_seconds{name}       unix-zeit (0 wenn down)
llm_service_downtime_estimate_seconds{name} schaetzsekunden, -1 = unbekannt
llm_customer_status_info{service,state,message,eta} 1   state: ok|investigating|degraded|down
llm_incident_open{severity}                1
Loki: job=incident, label service/alertname/severity/phase.

## Abgrenzung
sglang-Container und flash-next-Runtime werden nicht veraendert (Regel 2);
nur deren Metriken werden gelesen. Versandkanal Alertmanager bleibt bewusst leer
(Betreiberentscheidung 2026-11-16); der Incident-Agent ist der Empfang fuer diese Demo.

## Abnahme
make validate, make drift, make docs-build gruen; Prometheus zeigt alle neuen
Serien; drei Seiten liefern Live-Daten; Demo-Alarm erzeugt Ticket + Statuswechsel
nachweislich (Loki-Zeile, SQLite-Zeile, Panels).
