# Statusseiten und Vorfallspipeline (Runbook)

Dieses Dokument haelt die Telemetrie-Inventur, die drei Statusseiten, die
Vorfallspipeline mit Zustandsmaschine und die taeglichen Befehle. Die
allgemeine Beobachtungsstufe (Prometheus, Loki, Grafana, Alloy) ist in
[monitoring.md](monitoring.md) beschrieben.

## Telemetrie-Inventur (2026-11-18)

| Quelle | Liefert | Zustand |
|---|---|---|
| job `vllm` (Laufzeit :30000/metrics) | sglang-nativ: Token, Anfragen, Wahrscheinlichkeiten, KV, Praefix-Cache, Drosselung | aktiv, Spiegel in `06-sglang-betriebsdaten.json` |
| Kompatibilitaetsregeln (`runtime-compat.yml`) | `vllm:*`-Aliasserien + `sglang:kv_pool_usage` | 18 Regeln, aktiv |
| job `gpu` (nvidia-smi-Exporter) | Auslastung, Speicher, Takt, Leistung, Drosselzaehler | aktiv |
| job `node` (node_exporter + Textdatei) | Host, Dateisystem, plus `llm_*` aus `scripts/collect-stack-status.sh` | aktiv, Timer alle 30 s |
| job `incident-agent` | `incident_agent_*` (Ticketzaehler, Liveness) | aktiv |
| Loki `job="containerlogs"` | Container-Protokolle (Alloy->Journal), Labels `container`, `unit` | aktiv |
| Loki `job="incident"` | Vorfalls-Ereignisse und Zeitachse (`phase`-Label) | aktiv |
| Dozzle | Live-Log-View je Container (LAN, ohne Anmeldung - Betreiberentscheidung) | aktiv |

Messluecken (bewusst nicht erfunden):

* **cAdvisor liefert CPU-/Speicherzeit je Container** (job `cadvisor`, Unit-Label);
  Plattform-Seite
  zeigt Zustand, Neustartzaehler und OOM-Zaehler stattdessen.
* **DCGM fehlt** - daher keine XID-Fehler, kein ECC-Detail, keine
  PCIe-Geraetebreite, kein Prozessnutzungsanteil (nur Prozess-Speicher).
  Produktionspunkt: `scripts/65-install-gpu-exporter.sh` (dcgm-Zweig).
* **OpenShift/Kubernetes laeuft hier nicht** - die Plattform-Seite ist die
  Podman-Entsprechung (Pod->Container, Cluster->Host); ein echtes OpenShift
  haette zusaetzlich kube-state-metrics-Daten (Nodes, Replicas, PVs).
* **Splunk/Oracle/Postgres-EDB/MCP-Ticketsystem**: Adapter vorbereitet,
  deaktiviert (`config/monitoring/incident-agent-adapters.json`);
  Produktionspunkt ist dort je ein Eintrag plus die Adapterstubs in
  `scripts/incident-agent/server.py`.

## Die drei Statusseiten

| Seite | uid | Publikum | Antwort |
|---|---|---|---|
| Service-Status (Betrieb) | `llm-stack-status` | Einsatz/Ops | Gesamtzustand HEALTHY...MAINTENANCE/UNKNOWN, Zeitachse je Komponente, Grund, Schaetzung |
| Service-Status (Hotline) | `llm-hotline-status` | Annahme | Gibt es einen bekannten Vorfall, wer arbeitet daran, wann die naechste Meldung kommt |
| Service-Status (Kunde) | `llm-kunden-status` | Kunde/Leitung | Nur Kundenservices, Vorfallsbanner, Verfuegbarkeit, keine internen Namen |

Zusaetzlich: `llm-plattform` (Container-Sicht), `llm-incident-analyse`
(Zeitachse, KI-Hypothese, Problemrecord), `llm-sglang-live` (sgTop-Spiegel),
GPU-Deep-Dive in `llm-infra-gpu`. Homepage-Tab **SERVICE-STATUS** verlinkt
alles; Grafana bleibt die Tiefe, das Portal die Tuer.

## Vorfallspipeline

```
Prometheus-Regel (alerts.yml, Gruppe status)
  -> Alertmanager (Route -> POST http://llm-incident-agent:9104/webhook)
  -> Agent: Ticket (SQLite tickets.db) -> Beweise (Loki, Prometheus,
     Vorfallshistorie, Git-Spur) -> KI-Hypothese ueber das Gateway
  -> customer-status.json -> Sammler -> Prometheus -> Statusseiten
```

### Zustandsmaschine (verbindlich)

`detected -> acknowledged -> investigating -> cause-identified ->
mitigating -> monitoring (10 min) -> resolved`

Grundregeln, die der Agent erzwingt (auch im Prompt an das Modell):

1. **Keine erfundene Reparaturzeit.** Anzeige-ETA nur aus dokumentiertem
   Erfahrungswert (Spielplan-Tabelle in `server.py`) - Stufen `unbekannt`,
   `grobe-schaetzung`, `einengend`, `geplant`. Ein KI-Vorschlag ist immer nur
   Vorschlag und wird getrennt ausgewiesen.
2. **KI-Zuordnung = Hypothese mit Zuversicht** (`HIGH CONFIDENCE`,
   `PROBABLE`, `POSSIBLE`, `INSUFFICIENT EVIDENCE`), nie "Ursache".
   `BESTAETIGT (Messung)` bleibt gemessenen Fakten vorbehalten.
3. **Meldefrist statt ETA:** "Neue Meldung bis HH:MM" (30 Minuten),
   unabhaengig davon, ob die Wiederherstellung unklar ist.
4. **Gegentest:** meldet die Messreihe den Dienst durchgehend up, stuft der
   Agent die Hypothese auf `POSSIBLE` zurueck (Demo-Alarme werden so sichtbar
   entwertet).

### Befehle

```bash
./scripts/collect-stack-status.sh --pruefen        # naechste Sammlung ansehen
systemctl --user status llm-stack-status.timer     # Sammler-Timer
./scripts/80-setup-incident-agent.sh --check       # Agent-Pruefung
./scripts/80-setup-incident-agent.sh --demo        # Beispielalarm einspielen
podman exec llm-incident-agent python3 -c "import sqlite3 as s; \
  print(s.connect('/var/lib/incident-agent/tickets.db').execute( \
  'SELECT id,alertname,phase,zuversicht,eta_art FROM tickets ORDER BY id DESC LIMIT 5').fetchall())"
./scripts/set-maintenance.sh start litellm "Rollout" "12:30"   # Wartungsfenster
./scripts/set-maintenance.sh end litellm
```

Problemrecord freigeben (Menschenentscheid, Token in
`~/.config/llm-infra/incident-agent.env`):

```bash
# aus dem Agenten-Netz (Demo-Wechsel):
podman exec llm-incident-agent python3 -c "
import json,urllib.request,os
body={'ticket':1,'entscheid':'freigegeben','token':os.environ['APPROVE_TOKEN']}
r=urllib.request.Request('http://127.0.0.1:9104/approve',data=json.dumps(body).encode(),
    headers={'Content-Type':'application/json'})
print(urllib.request.urlopen(r,timeout=10).read().decode())"
```

Vor dem naechsten Demo-Durchlauf koennen alle Tickets geschlossen werden
(`UPDATE tickets SET phase='resolved'`), sonst verhindert die Duplikatregel
ein neues Ticket derselben Art.

## KV-Cache: warum die Anzeige oft bei ~90 % steht

Der Poolwert `llm_*`/`sglang:token_usage`-Familie zaehlt **genutzte plus
verdruengbare** Token gegen die Gesamtkapazitaet. Der Praefix-Cache (Radix)
haelt abgeschlossen Prompt-Blocke als "evictable" fest - der Pool ist damit
dauerhaft voll, obwohl die effektive Nutzung (sgtop-Anzeige) bei etwa 40 %
lag (gemessen 2026-11-18: Pool 0,91, effektiv 0,43). Die Betriebspanels zeigen
deshalb drei Werte: effektive Nutzung, Pool inklusive Cache, freier Kopf.
Details und Formel in [monitoring.md](monitoring.md#kvcache).

## Abnahme (Vision-Kontrolle)

Abnahme pro Dashboard: Screenshot plus DOM-Pruefung (Panelzahl, Titel,
Fehler-/Leermeldungen, Ueberlauf, was oberhalb der Falzkante liegt):

```bash
bun scripts/grafana-dashboard-qualitaet.mjs llm-kunden-status llm-hotline-status llm-stack-status
# Bilder: docs/screenshots/<uid>.png, Bericht als JSON auf der Standardausgabe
```

Pruefpunkte: Einheiten stimmen, Legendentext lesbar, keine Panel-Fehler,
Gesamtzustand und Vorfallsbanner oberhalb der Falzkante, keine Ueberlaeufe
ueber 24 Spalten. Die Bilder sind Beweismittel; der Bericht ist die
maschinenlesbare Abnahme.

Bisherige Abnahme (2026-11-18): alle elf Dashboards rendern ohne Panel-Fehler;
Bilder unter `docs/screenshots/` (Normalzustand, dazu Stoerungs- und
Wartungszustand der vier Statusseiten). Zwei Befunde wurden dabei behoben:
Ein Overlay-Matcher mit `id: "name"` statt `byName` reisst in Grafana 12 die
ganze Seite um (Konsolenfang noetig, das Panel zeigt nur "Page error"); und
`vllm:request_success_created` existiert auf der SGLang-Laufzeit nicht
(Betriebszeit nutzt `process_start_time_seconds`).
