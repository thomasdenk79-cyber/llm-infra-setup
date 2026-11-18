# Monitoring-Betrieb (Stand 2026-11-16)

Stack: Prometheus (Scrape) + Alertmanager (Alarmweitergabe) +
Alloy/loki.source.docker und loki.source.journal (Logs -> Loki) + Grafana
(Dashboards, Datei-provisioniert, aenderbar NUR ueber dieses Repo) +
node/gpu-exporter + Textfile-Collector.

## Datenflusse
- Metriken: Exporter -> Prometheus (30d Retention) -> Grafana.
- Alarmsaetze: Prometheus (`alerting:`-Block) -> Alertmanager -> Kanal
  (Kanal bewusst noch zu, siehe Abschnitt Alarmkanal).
- Logs: Podman-Socket -> Alloy -> Loki -> Grafana Explore/Dashboards.
- Logs der unmanaged Runtime (flash-next-v3): Journald -> Alloy
  `loki.source.journal` -> Loki (Grund im Abschnitt Alloy unten).
- Host-Fakten (llm_*): `scripts/collect-host-facts.sh` alle 30s ueber
  systemd-user-Timer `llm-infra-collect-facts.timer` in den Textfile-Ordner.
  Ausfall der Fakten? -> `systemctl --user status llm-infra-collect-facts.timer`.

## Neu seit 2026-11-16 (Beobachtungsstapel)

### Alertmanager (der Alarmweg)

`quadlet/alertmanager.container` (Bild `docker.io/prom/alertmanager:v0.27.0`)
haengt an `llm-observability.network`, alias `alertmanager`, und ist auf dem
Host nur unter `127.0.0.1:9093` erreichbar. Die Konfiguration kommt schreibgeschuetzt
aus `config/monitoring/alertmanager.yml`, der Zustand liegt unter
`~/.local/share/llm-infra/alertmanager`. Prometheus meldet ihm die Regeln ueber
den `alerting:`-Block in `config/monitoring/prometheus.yml` (target
`alertmanager:9093`). Ohne diesen Block werten sich die Regeln in `alerts.yml`
zwar aus, landen aber nirgends - ein defekter Alarm, der nie laut wird. Der
Alertmanager ist Teil von `OBSERVABILITY_UNITS` in `lib/units.sh` und wird von
`./scripts/60-install-monitoring.sh` mitinstalliert. Eine Inhibit-Regel
(`BeobachtungZieltNicht` unterdrueckt bei ausgefallenem Collector die Alarme
desselben `job`-Labels) verhindert eine Lawine doppelter Meldungen.

Pruefen:

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:9093/-/ready   # muss 200 sein
curl -s http://127.0.0.1:9093/api/v2/alerts | python3 -m json.tool | head
```

### Alarmkanal

Die Weiterleitung ist bewusst ohne Versand ausgeliefert: ntfy und E-Mail sind
in `config/monitoring/alertmanager.yml` vorbereitet und auskommentiert. Solange
der Betreiber keinen der beiden Kanaele waehlt, bleiben alle Alarme im
Alertmanager unter `http://127.0.0.1:9093` und in der Prometheus-Oberflaeche
sichtbar, statt ungelesen in ein leeres Postfach zu gehen.

**Betreiberentscheidung vom 2026-11-16: ohne Empfaenger.** Kein Kanal ist getragen,
und das ist der Soll-Zustand, keine offene Baustelle. Gewechselt wird erst, wenn
Alarme regelmaessig gelesen werden sollen; die beiden vorbereiteten Kanaele sind
dann in zwei Zeilen aktiviert (Telegram ist hier nicht vorgesehen - der vorbereitete
Push-Kanal ist ntfy ohne Konto).

- ntfy: ohne Konto, nur ein frei gewaehltes Themenwort auf dem Handy
  (`uri: https://ntfy.sh/<eigenes Themenwort>`).
- E-Mail: braucht SMTP-Zugang des Betreibers; das Passwort kommt aus
  `~/.config/workstation/secrets.env` (`ALERT_SMTP_PASS`), niemals als
  Klartext ins YAML.

Aktivieren: im Receiver `hinweise` den passenden Block (`ntfy_configs` oder
`email_configs`) einkommentieren, dann den Dienst neu starten und die
Uebernahme pruefen:

```bash
nano config/monitoring/alertmanager.yml
systemctl --user restart alertmanager.service
curl -s http://127.0.0.1:9093/api/v2/status | python3 -c 'import json,sys;print("cluster:",json.load(sys.stdin)["cluster"]["status"])'
```

### Alloy: Journal-Stroeme fuer flash-next-v3

Zwei Aenderungen an `quadlet/alloy.container` waren noetig; ohne sie lieferte
`loki.source.journal` null Stroeme:

- `Volume=/var/log/journal:/var/log/journal:ro` - die Komponente liest ueber
  libsystemd und braucht dafuer die Journal-Dateien im Container. Fehlt der
  dauerhafte Ordner `/var/log/journal` auf dem Host, lehnt Podman die
  Bind-Quelle ab; `scripts/60-install-monitoring.sh` weist dann mit den drei
  sudo-Befehlen darauf hin.
- `--server.http.listen-addr=0.0.0.0:12345` im Exec - standardmaessig
  lauscht Alloy nur auf `127.0.0.1` seines Containers; ohne die Bindung auf
  `0.0.0.0` ist er im Containernetz unter seinem Alias nicht ansprechbar und
  der Prometheus-Job `alloy` bleibt down.
- `--disable-reporting` im Exec - ohne die Flagge meldet Alloy alle paar
  Minuten die aktiven Komponenten an `stats.grafana.org`. Von diesem Rechner
  gibt es aus dem Observability-Netz keinen DNS/Egress dorthin; jeder Versuch
  scheitert nach Timeout und fuellt das Journal (gemessen 2026-11-18, drei
  Fehlserien je Minute). Die Flagge ist reine Protokollhygiene - Sammlung und
  Zustellung der Logs haengen nicht daran.

Warum ueberhaupt Journal statt Docker-API: `flash-next-v3` wurde mit
`podman run` gestartet und schreibt mit Logtreiber journald. Die
Docker-kompatible API des Podman-Sockets liefert fuer diesen Treiber keinen
Logstream (`error inspecting Docker container ... no such container` im
Alloy-Log), deshalb war die vLLM-Ausgabe bisher unsichtbar. In
`config/monitoring/alloy.alloy` liest jetzt `loki.source.journal` mit
`matches = "CONTAINER_NAME=flash-next-v3"`, eine relabel-Regel (`keep` auf
`__journal_container_name`) sichert ausdruecklich ab, dass kein anderer
Container mitkommt.

Pruefen (liefert Ziffern pro Container, flash-next-v3 muss dabei sein):

```bash
curl -sG 'http://127.0.0.1:3100/loki/api/v1/query' \
  --data-urlencode 'query=count by (container) ({job="containerlogs"})' | head -c 400
```

### Prometheus: neue Jobs und zwei bewusst auskommentierte

Neu aktiv in `config/monitoring/prometheus.yml`:

| Job | Target | Sinn |
|---|---|---|
| `grafana` | `grafana:3000` | Panels koennen still sein, ohne Alarm - der Job macht es zum Alarm (`BeobachtungZieltNicht`) |
| `alloy` | `alloy:12345` | Protokollsammler aus, keine Logs in Loki -> `ProtokollsammlungSteht` |
| `alertmanager` | `alertmanager:9093` | Alarmweg kaputt -> `AlarmwegFehlt` |
| `caddy` | `llm-proxy:8080` | Der LAN-Proxy ist ein eigener Dienst und braucht ein Metrikziel (Regel in `AGENTS.md`). Der Port ist nicht veroeffentlicht; durchgereicht wird nur `/metrics` auf den Caddy-Admin-Endpunkt, der den Host-Wert auf `127.0.0.1:2019` braucht (sonst 403) |
| `vllm` | `host.containers.internal:30000` | Runtime metrics (vLLM or SGLang) scraped directly on the stable runtime port via the host gateway (`AddHost=host.containers.internal:host-gateway`); the runtime must bind 0.0.0.0. `config/monitoring/runtime-compat.yml` records `sglang:*` under the `vllm:*` names used by dashboards and alerts |

Nach jeder Aenderung an `config/monitoring/prometheus.yml` oder `alerts.yml`:
`systemctl --user reload prometheus.service` (SIGHUP). Prometheus kennt kein
selbsttaetiges Neuladen - ein Flag wie `--config.reload.interval` gibt es nicht,
und der Versuch bringt die Unit in eine Crash-Schleife. Gemaenderte Dateien
erreichen den Container zuverlaessig, weil der Ordner
`config/monitoring` nach `/etc/prometheus/conf` gemountet ist statt der
Einzeldateien (Einzel-Datei-Bindungen folgen keinem Inode-Wechsel, `git pull`
aber tauscht sie aus).

Ist-Zustand am 2026-11-16: alle acht Jobs up. Der Job `grafana` war zeitweise
down, und zwar nicht wegen Grafana, sondern wegen des Unterpfads:
`GF_SERVER_ROOT_URL` bewirkt, dass Grafana `/metrics` per 301 auf die
oeffentliche https-Adresse umleitet, und Caddys interne CA vertraut Prometheus
nicht (`x509: certificate signed by unknown authority`). Beoben war der Scrape
im Containernetz direkt auf `/grafana/metrics` - eingetragen als `metrics_path`
im Job (Generatoren-Aenderung in `config/monitoring/prometheus.yml`). Beleg:

```bash
curl -s 'http://127.0.0.1:9090/api/v1/targets' | python3 -c '
import json,sys
for t in json.load(sys.stdin)["data"]["activeTargets"]:
    print("%-14s %-6s %s" % (t["labels"]["job"], t["health"], t.get("lastError","")[:90]))'
```

Zwei Jobs stehen auskommentiert in der Datei, die Begruendung steht dort als
Kommentar (waortlich):

- `pennyroyal`: "Pennyroyal ist auf diesem Rechner nicht im Einsatz: die
  Inferenz-Laufzeit ist vLLM (job \"vllm\" unten). Der Block bleibt fuer
  Rechner mit Pennyroyal erhalten und wird dort wieder ausgkommentiert; als
  totes Target wurde er sonst dauerhaft als Alarm schlagen."
- `litellm-liveliness`: "/health/liveliness ist der einzige keyless Endpunkt
  des Gateways, antwortet aber mit application/json - Prometheus kann daraus
  keine Messgroessen bilden (Fehler: unsupported Content-Type). ... Die
  Gateway-Laufzeit wird ueber llm_unit_active{unit=\"litellm\"} ueberwacht
  (siehe scripts/collect-host-facts.sh und config/monitoring/alerts.yml)."
- Zusaetzlich der Schluesselblock `litellm` (/metrics): der Chainguard-Bau des
  LiteLLM-Containers enthaelt kein prometheus-client, /metrics liefert 404;
  mit gueltigem Schluessel 404, ohne 401. Freischaltweg steht im Kommentar
  (eigenes Image mit prometheus-client, Schluessel nur als Secret-Datei).

### Alarmregeln auf die vLLM-Messgroessen umgelenkt

`sglang:*`-Messgroessen existieren auf diesem Rechner nicht; die Regeln sind
samtlich auf die vorhandenen `vllm:*`-Messgroessen umgelenkt
(`config/monitoring/alerts.yml`): `RuntimeNichtErreichbar` (`up{job="vllm"}`,
for 15m wegen Kaltstart), `RuntimeOhneFortschritt`, `VorlaufzeitZuHoch`,
`SchreibrateGering`, `VorhersageWirktNicht`, `KVSpeicherVolllaeuft`. Kein `sglang`
kommt in den Dashboards und Regeln mehr vor (Pruefung: `grep -c sglang
config/monitoring/alerts.yml` liefert 0).

Syntax mit dem mitgelieferten promtool im laufenden Container pruefen:

```bash
podman exec systemd-prometheus promtool check rules /etc/prometheus/conf/alerts.yml
```

### Grafana-Unterpfad (Voraussetzung der oeffentlichen Route)

Der oeffentliche Zugang der Kollegen bedient mehrere Dienste aus einem
Caddy-Serverblock an 443; Grafana sitzt dabei unter `/grafana/`
(`docs/gateway-proxy.md`). Damit login-Seite und Dashboards nicht ungestylt
erscheinen, muss Grafana seine Links und Assets selbst unter diesem Unterpfad
anbieten. Die zwei Einstellungen haengen am Gateway-Namen und liegen deshalb
ausserhalb von Git in `~/.config/llm-infra/grafana.env` (0600): Vorlage ist
`config/grafana.env.example`, erzeugt wird die Datei von
`scripts/60-install-monitoring.sh` (mit dem DNS-Namen aus
`config/gateway-proxy.env`). Das Quadlet `quadlet/grafana.container` bindet sie
als `EnvironmentFile` ein.

Pruefen:

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3000/grafana/api/health   # 200
```

## Bekannte Datengrenzen (bewusst, kein Bug)
| Signal | Wo verfuegbar | Warum |
|---|---|---|
| llm_zfs_*, llm_smart_*, node_zfs_* | nur echter KVM-CachyOS-Host | WSL: kein ZFS, keine nvme-Devs |
| llm_pcie_* | nur echter Host | WSL haengt GPU an dxgkrnl, lspci blind |
| node_cpu_scaling_frequency_hertz | nur echter Host | WSL zeigt keinen cpufreq-Treiber |
| Pennyroyal Warnung "CP delta rule" | - | flashinfer upstream-Fallback, folgenlos |
| Tokenwarnung 262682>262144 | - | Base-Tokenizer-Check vor YaRN-Faktor 2.0, Fehlalarm moeglich; beobachten |

## Fixed 2026-10-08
1. node-exporter schrie 720 Fehler/3h: WSL dubliziert /run/user-tmpfs ->
   `--collector.filesystem.mount-points-exclude='^/run/user(/.*)?$'`.
2. llm_*-Fakten fehlten komplett: Timer war nie installiert -> enabled.
3. Open-WebUI quatschte totes Ollama an -> ENABLE_OLLAMA_API=false.
4. Homepage-Konfig lebte ausserhalb des Repos -> nach config/homepage/
   umgezogen, Quadlet-Mount geaendert (GitOps jetzt konsistent).
5. Grafana-Dashboards 02/04 bekennen ihre WSL-Datengrenze als Hinweis-Panel.

## Beobachtungsliste
- litellm "Malformed API Key" / "No api key passed in." war die Welle
  keyloser Prueflaeufer gegen /health und /metrics (beide master-key-
  geschuetzt). Behoben 2026-10-08: interne Tests auf keyless
  /health/liveliness umgestellt; Scrape-Vorlage dokumentiert. Taucht es
  wieder auf: Loki `job="litellm" |= "Malformed"` nach Client-IP durchsuchen
  und docs/troubleshooting.md#gateway-log-voll-401 no api key passed in --malformed-api-key folgen.
- Alloy meldet nach Container-Recreates kurz "no such container" (selbstheilend).
  Gemessen 2026-11-18: nach jeder Containertloeschung retryt `loki.source.docker`
  die tote ID noch bis zur naechsten Discovery-Aktualisierung (Standard 1 Minute,
  Retry alle 5 Sekunden); der Abbau ist im Journal mit "removing entry from
  positions file" belegt. Kein Handeln noetig — ausser der Betreiber moechte
  das Experimentier-Churn der sglang-Container reduzieren.
- Prometheus-Job `grafana` war nach der Unterpfad-Umstellung down (301 auf die
  oeffentliche Adresse, x509 der Caddy-CA). Behoben 2026-11-16: `metrics_path:
  /grafana/metrics` im Job, damit der Scrape im Containernetz bleibt. Beleg im
  Abschnitt "Prometheus: neue Jobs und zwei bewusst auskommentierte".
