# Aenderungsprotokoll
## 2026-11-16 – Oeffentlicher Zugang, Alarmweg, Beobachtungskorrektur

- Irrtum zurueckgenommen: die entfernte
  `ExecStartPre=%h/forge/watchdog/reference-start-gate.sh` war nicht der Grund fuer
  rotes `make drift`. Die committete Referenz-Unit weicht in Bild, `Description`,
  `Ulimit`-Zeilen und Modellpfad von der Generator-Ausgabe ab; die Zeile ist wieder drin.
  Welche Fassung die Referenz ist, entscheidet der Betreiber (siehe `docs/HANDOFF.md`).
- Doku-Gaenge wieder lauffaehig: `make docs-build` schlug fehl, weil mkdocs auf diesem
  Rechner kein Systempaket ist. Neu `scripts/install-docs-tooling.sh` (idempotent, legt
  die Umgebung unter `~/.local/share/llm-infra/docs-venv` an, Version aus `versions.lock`),
  das Makefile nutzt sie ueber `MKDOCS`. `make docs-build` (mkdocs --strict) laeuft durch;
  die fuenf bis dahin unverlinkten Seiten (Pruefprotokoll, Ubuntu-Uebergabe,
  Siemens-LLM-API, Recht, Messmatrix) haengen jetzt in der Navigation.
- Fehler im Weiterleiter der Modell-API behoben: `socket.create_connection(..., timeout=10)`
  setzte auch das Lese-Timeout der Laufzeitseite. Wartete die Laufzeit bei Auslastung
  laenger als 10 s bis zum ersten Token, brach der Stuck-Strom ab und LiteLLM meldete
  `TransferEncodingError: Not enough data to satisfy transfer length header` (Gateway 502
  auf alle lokalen Modelle). Timeout gilt jetzt nur fuer den Verbindungsaufbau.
  Neuartige Regressionspruefung: `scripts/test-vllm-forwarder.sh` mit einem langsamen
  Vorgaetter (13 s bis zum ersten Byte); rot gegen die alte Fassung, gruen gegen die neue.
- Repo umgezogen nach `/srv/work/llm-infra-setup`; alle Docs auf diesen Pfad
  gezogen (README und install.md folgen, siehe offene Punkte).
- Gateway-Unit neu geschrieben: die unverwaltete `reverse-tunnel.service`
  (Direkt-Tunnel ohne `permitlisten`) ist gestoppt, deaktiviert und
  wiederherstellbar umbenannt auf
  `~/.config/systemd/user/reverse-tunnel.service.retired-20261116`. Neu ist
  die verwaltete `llm-reverse-tunnel.service` (autossh, `-N`,
  `ExitOnForwardFailure=yes`, jeder Forward auf Loopback) aus
  `scripts/70-setup-gateway-proxy.sh` mit eigenem Tunnel-Schluessel,
  `authorized_keys`-Zeile mit `restrict,port-forwarding,no-agent-forwarding,no-X11-forwarding` plus
  `permitlisten` nur fuer `127.0.0.1:4000|3000|3002`
  und Erstversorgung ueber `GATEWAY_BOOTSTRAP_KEY`.
- Oeffentlicher Zugang nur ueber Port 443 des Azure-Gateways
  (`edipoc-gateway.westeurope.cloudapp.azure.com`, 20.73.54.102): Caddy
  rendert die Vorlage `config/gateway/Caddyfile.template`, Admin-API auf 127.0.0.1:2019,
  Vorher-Sicherung `/etc/caddy/Caddyfile.bak.<UTC>`. Routen gemessen:
  `/health/liveliness` 200, `/v1/models` 401 ohne Schluessel, `/` 401,
  `/grafana/` 401; Roh-IP gleich, mit Zertifikatswarnung (`tls internal` +
  `default_sni`). Basic-Auth-Personen in
  `~/.config/llm-infra/gateway-proxy/team-users.txt` (5: owner, thomas,
  martin, johannes, holger). Doku: `docs/gateway-proxy.md`.
- Alertmanager aufgenommen (`quadlet/alertmanager.container`,
  prom/alertmanager:v0.27.0, nur 127.0.0.1:9093,
  `config/monitoring/alertmanager.yml`); Prometheus meldet ueber den
  `alerting:`-Block. Kanaele (ntfy, E-Mail) sind vorbereitet und bewusst
  deaktiviert, bis der Betreiber waehlt (`docs/monitoring.md#alarmkanal`).
  Damit laufen die Regeln nicht mehr ins Leere; erster Nachweis: 3 aktive
  Alarme im Alertmanager.
- Alloy-Journal-Fix: `/var/log/journal` nur-lesend eingehaengt und
  `--server.http.listen-addr=0.0.0.0:12345`; ohne beides lieferte
  `loki.source.journal` null Stroeme. flash-next-v3 (journald-Logtreiber,
  Docker-API liefert dazu keinen Stream) ist jetzt ueber
  `CONTAINER_NAME=flash-next-v3` in Loki sichtbar.
- Alarmregeln von `sglang:*` auf die tatsaechlich vorhandenen `vllm:*`
  umgelenkt (`config/monitoring/alerts.yml`, kein sglang-Verweis mehr); dazu
  neue Jobs `grafana`, `alloy`, `alertmanager` und `vllm` in
  `config/monitoring/prometheus.yml`; `pennyroyal` und `litellm-liveliness`
  bleiben mit Begruendung im Kommentar auskommentiert.
- Dashboards auf vLLM umgelenkt und an die Loki-Datenquelle
  (uid P8E80F9AEF21F6940) angeschlossen; drei Panels ohne Anfrage
  ("Auslastung je Geraet", "VRAM-Bedarf je Geraet", "VRAM-Fuellstand") gegen
  lebende `nvidia_smi:*`-Abfragen getauscht. Stand: 121 Panel-Abfragen, keine
  sglang-Referenz. Browser-Pruefung (Playwright, Chromium headless, eingeloggt):
  89 Panelfelder, 8 ohne Daten - ausschliesslich ZFS/ARC-Panels aus
  `04-speicher.json` (dieser Rechner hat kein ZFS; sie zeigen "keine Daten"
  als Hinweis), alle uebrigen gefüllt.
- Grafana-Unterpfad: `~/.config/llm-infra/grafana.env`
  (`GF_SERVER_ROOT_URL=.../grafana/`, `GF_SERVER_SERVE_FROM_SUB_PATH=true`),
  erzeugt von `scripts/60-install-monitoring.sh`, Vorlage
  `config/grafana.env.example`. Nebenwirkung war der down-Job `grafana`
  (301 auf die oeffentliche Adresse, x509 der Caddy-CA); behoben mit
  `metrics_path: /grafana/metrics` im Job - Beobachtung in `docs/monitoring.md`.
- Wiki in Betrieb: `~/work/hermes-wiki` geklont, `site/`-Build ueber
  `scripts/wiki-rebuild.sh` (venv + mkdocs-material), `wiki-rebuild.timer`
  enabled+aktiv, `wiki.service` liefert http://127.0.0.1:3003/ (200).
- Runtime ist auf diesem Rechner der unmanaged Container `flash-next-v3`
  (127.0.0.1:30000, kein Pennyroyal); Metriken ueber die Repo-Unit
  `llm-vllm-forwarder.service` (`scripts/73-setup-vllm-forwarder.sh` +
  `scripts/vllm-pub-forwarder.py`), Bindung Loopback plus Host-Adressen,
  Begruendung in `docs/runtime.md`. Die auswaertige `luni-vllm-pub.service`
  ist gestoppt, deaktiviert und umbenannt auf
  `~/.config/systemd/user/luni-vllm-pub.service.retired-20261116`.
  LiteLLM: der Generator
  nimmt `chatgpt/gpt-6-luna` erst auf, wenn unter
  `~/.config/llm-infra/chatgpt-tokens` ein echtes Geraet-Token liegt; ohne
  Token wird das Modell ausgesteuert, weil der ungebundene
  OpenAI-Device-Code-Flow die Bindung von :4000 verhindert haette.
- Persoenliche Virtual-Keys: `scripts/71-gateway-keys.sh` legt das Team `luni`
  an (ohne Team lehnt LiteLLM Schluessel mit 404 ab), stellt pro Person einen
  Schluessel aus, listet (`--list`, maskiert) und widerruft (`--revoke`) nach
  Alias oder Hash. Ausgestellt fuer owner, thomas, martin, johannes, holger;
  Ablage `~/.config/llm-infra/gateway-proxy/issued-keys.txt` (0600).
  Chat-Antworten gemessen: lokal ueber 4000, oeffentlich ueber 443 (DNS und
  Roh-IP) mit personifiziertem Schluessel.
- OpenCode an den Gateway angebracht: `scripts/72-setup-opencode.py` schreibt
  die Provider `luni-gateway` (Loopback) und `luni-oeffentlich` (443) in
  `~/.config/opencode/opencode.jsonc`, legt Schluessel und Gateway-CA unter
  `~/.config/llm-infra/gateway-proxy/` ab und sichert die Betreiberdatei mit
  Zeitstempel. Der bisherige Platzhalter `apiKey: "local"` war gegen den
  schluempflichtigen Gateway 401. Die Caddy-CA wird auf Wunsch
  (`--ca-import`) als Systemtrust verankert - Bun beruecksichtigt
  `NODE_EXTRA_CA_CERTS` nicht, ohne Verankerung bricht der oeffentliche Pfad
  mit `UNABLE_TO_GET_ISSUER_CERT_LOCALLY`.
- Portal (Homepage) repariert: `HOMEPAGE_ALLOWED_HOSTS` kommt aus
  `config/host.env` (die laufende Unit erlaubte noch 8443- und LAN-Hosts),
  das ununterstuetzte `rss`-Widget ist weg, die Grafana-Karten zeigen jetzt
  auf `/grafana/`, die Komodo-Karte (Dienst nicht installiert) ist entfernt,
  Alertmanager und Laufzeit sind ergaenzt, und `bookmarks.yaml` nutzt das
  Format, das v2.4.0 wirklich liest (`href`). Das Laufzeit-Protokoll
  `config/homepage/logs/homepage.log` ist aus dem Git-Index genommen.
- Defekter Rueckbau in `scripts/check-drift.sh`: bei gefundener Drift stellte
  das Skript den committeten Stand eigenhändig wieder her
  (`git restore -- quadlet config/litellm.yaml`) und vernichtete damit
  unbeabsichtigt eigene Arbeit. Jetzt bleibt das Arbeitsverzeichnis
  unveraendert; der Rueckbau braucht ein ausdrueckliches `--restore`.
- Doku: `docs/gateway-proxy.md` (neu, erfuellt die
  `Documentation=`-Angabe der Tunnel-Unit) und `docs/runtime.md` (neu) sind in
  `mkdocs.yml` navigierbar; `versions.lock` auf gemessenem Stand (LiteLLM
  v1.105.0, Alertmanager v0.27.0, Runtime-Bild mit Digest, Caddy, mkdocs-material).
- Verifikation: `--check`-Pfade der Skripte, `curl`-Messungen lokal und
  oeffentlich (siehe `docs/status.md`), Alertmanager `/-/ready` 200, alle
  Targets ausser `grafana` up.

## 2026-10-08 – Gateway-Haertung: Monitoring-Auth, Waechter, Drill

- Root-Cause 401-Welle: interne Prueflaeufer ohne gueltigen Bearer trafen die
  master-key-geschuetzten Endpunkte /health und /metrics: der Repo-eigene
  healthcheck.sh und llmctl prueften /health (401 ohne Key -> "Gateway nicht
  erreichbar" als false negative), doctor.sh nutzte den Liveness-Alias, dazu
  Client-Sondierungen aus dem Inferenz-Netz (Open-WebUI-Muster /api/tags,
  /props, /version unmittelbar vor jeder "Malformed"-Zeile; rotierende
  Container-IPs 10.89.1.x). Folge: "No api key passed in." / "Malformed API
  Key ... Bearer prefix" mit Traceback im Journal. Befund 12h-Journal: 57x
  "No api key", 8x "Malformed". Kein aktiver Prometheus-Litellm-Target im
  Live-Config (ueber /api/v1/targets verifiziert); /metrics liefert selbst mit
  gueltigem Key 404 (Chainguard-Image ohne prometheus-client). Fix: alle
  internen Tests auf das keyless /health/liveliness umgestellt
  (healthcheck.sh zeigte "Gateway nicht erreichbar" als false negative trotz
  200er Liveliness), Prometheus-Vorlage dokumentiert keyless Liveness-Scrape
  und Bearer-nur-als-Secret-Datei. Keine Secretwerte im YAML (validate rc=0,
  promtool SUCCESS).
- Neu: scripts/litellm-watchdog.sh + systemd/llm-litellm-watchdog.{service,
  timer} (5 min): Liveliness + 1-Token-Smoke; restartet bei Ausfall ausschliesslich
  litellm.service, mit running_reqs-Schutz, GPU-Lock-Guard (flock -n auf
  ${XDG_RUNTIME_DIR}/copilot-sm120-gpu.lock) und 3er-Loopsperre. Guard-Pfad
  getestet (Sperre belegt -> keine Aktion, rc=0). Timer aktiv.
- Neu: scripts/litellm-failover-drill.sh - Wegwerf-Container litellm-drill
  (:4013) mit totem Primaer (:4099); beweist KETTE OK. Letzter Lauf:
  kettenuebergabe 22,2s -> bonsai-2-27b (tok=2), bonsai direkt 0,27s, luna
  direkt 1,73s (tok=5, 'Sure'). Erstbeweis der Kette: 9,78s gesamt, ~45 tok/s.
  Luna braucht temperature-freie Anfragen (400 Bad Request sonst) - im Drill
  beruecksichtigt.
- Hermes-"Clean EOF, no finish_reason": zwei Klassen. (1) Restart-Artefakt:
  die Warnungen 11:52:33/11:54:02/11:54:23 liegen unmittelbar um den
  litellm-Neustart 11:51:39-11:51:53 (Streams, die den Container-Stopp
  ueberlebten, enden sauber ohne Schlusspaket). (2) Vereinzelte Faelle ohne
  Neustartfenster (11:40-11:50, 11:10, 09:13, 08:17) - ob clientseitige
  Abort-Streams oder ein Upstream ohne finish_reason endet, bleibt offen;
  kein Muster eines reproduzierbaren Kettendefekts.
  Doku beschreibt die Unterscheidung (Neustartfenster pruefen, sonst Kette
  per Drill durchmessen).
- Doku: operations.md (Drill, Waechter, Luna-Token-Persistenz,
  Monitoring-vs-Key-Endpunkte), troubleshooting.md (401-Klasse, Luna-Token,
  Clean EOF), monitoring.md Beobachtungsliste aktualisiert.
- Querverweis: schliesst eine M4-artige Luecke (Ist-vs-Soll ohne aktiven
  Nachweis) aus docs/GRAFANA-DRIFT-AUDIT-2026-10-08.md; Audit selbst unveraendert.

## 2026-10-08 – Bonsai 2 als LiteLLM-Fallback

- Bonsai 2 27B PTQ1_0 wird auf der RTX 3500 Ada durch Prism-llama.cpp als rootless WSL-Quadlet auf Port 8082 bereitgestellt (8192 Kontext, Q8-KV).
- LiteLLM-Fallback unter separatem Modellnamen `bonsai-2-27b`; die Primaergruppe `qwen3.8-flash-next` verweist ueber `router_settings.fallbacks` darauf. Generator nutzt optionalen `FALLBACK_API_KEY` aus der lokalen Runtime-Environment-Datei; kein Key-Wert im Git.
- Verifikation: `make validate` bestanden; separater Proxy mit totem Primaer gab eine Bonsai-Completion zurueck (45,1 Token/s). Live-Gateway neu gestartet, Health 200; Pennyroyal ebenfalls Health 200. Blackwell-VRAM blieb bei ca. 93,2 GiB.

## 2026-10-08 – Grafana: Dashboards zeigen wieder Daten

- Ursache: Prometheus-Container ohne Netz-Alias `prometheus`; die
  Grafana-Datenquelle `http://prometheus:9090` lief in einen DNS-Fehler
  (`lookup prometheus ... no such host`), alle Panels "no data" obwohl alle
  Scrape-Ziele `up` waren.
- Zusatzfehler: Dashboard-JSONs referenzierten nicht-existente Datenquellen-UIDs
  (`prometheus`, `loki`) bzw. vertauschte UIDs (01); `rotate-secrets.sh`
  exec-te in den Container-Namen `grafana` statt `systemd-grafana` und konnte
  das Admin-Passwort deshalb nie in der Grafana-DB realignen; Grafana 12
  Passwort-Politik lehnte das generierte Hex-Passwort ab.
- Fix: `NetworkAlias=prometheus` (quadlet + installierte Unit), feste
  `uid:`-Felder in `datasources.yml`, alle Panel-UIDs normalisiert,
  PCIe-Panel auf `nvidia_smi_pcie_link_*` umgestellt, rotate-secrets korrigiert.
- Verifikation: 79/95 Panel-Abfragen liefern ueber `/api/ds/query` Daten
  (vorher 0/95 ueber Prometheus-Proxy); Loki-Log-Panels direkt gegen
  `/loki/api/v1/query_range` bestaetigt. Restluecken = WSL-Umgebungsgrenzen
  (ZFS/SMART/Takt nur auf echtem Host), dokumentiert unter Datengrenze.


## Diagnose WSL/Pennyroyal (2026-10-07)

* WSL-Startwerte fuer Loader, OMP, Torch-Compile und Build auf je 4 begrenzt;
  HiCache von 32 auf den Projektstandard 8 GiB zurueckgesetzt. Das ist ein
  konservativer Diagnoselauf, keine Leistungsoptimierung.
* Ein Startfehler war nachweislich kein OOM: PyTorch beendete sich mit Exit 1,
  weil `CUDA_VISIBLE_DEVICES=1` im Container kein CUDA-Geraet sichtbar machte.
* Kernel-Journal und Coredumpctl zeigten keine OOM-Kills oder Core Dumps.
  Prometheus erfasst Host-RAM/Swap, aber keine Pennyroyal-Container-RAM-Zeitreihe.

## Unveroeffentlicht (Review- und Ausbauphase, 2026-10-02)

Behoben (Zustand des Rechners war betroffen):

* PLE-Speicher fehlte nach einem Neustart: der `nofail`-Eintrag in `/etc/fstab`
  wurde nie geschrieben, obwohl Skript und Doku das behaupteten. Jetzt wird er
  gesetzt und durch `--verify` sowie die Kennzahl `llm_ple_in_fstab` ueberwacht.
* Prometheus konnte die Runtime nicht erreichen (zwei getrennte Netze).
  Prometheus haengt jetzt an beiden Netzen, die Runtime bleibt einhuehnig.
* Grafana hatte keinen Passwort-Zugriff mehr (leeres Podman-Secret) und haette
  ohne Secret gar nicht gestartet; Secret wird jetzt zuverlaessig erzeugt.
* Die Runtime-Unit wurde ohne Healthcheck-Befehl und ohne `RestartSec` gestartet;
  Haengen fuehrte zu keinem Neustart. Jetzt `HealthCmd`, `RestartSec`,
  `TimeoutStartSec` und ein optionaler Waechter-Timer.
* `./setup.sh` ueberschrieb die OpenCode-Konfiguration ungefragt; jetzt nur noch
  anlegen, wenn keine Datei existiert, sonst Vorlage daneben.
* `flock` meldete Erfolg, obwohl ein anderer Lauf aktiv war (Exit 0 statt 75).
* Zwei Deploy-Skripte installierten dieselben Units unterschiedlich; jetzt eine
  gemeinsame Installationsregel in `lib/units.sh` inklusive Platzhalterersetzung.
* Nach der Umbenennung von Einheiten blieben Altdateien im User-Ordner und
  bringen sich gegenseitig zum Neustart; Deploy laeuft jetzt
  `prune_legacy_units`.
* Prometheus-Dienst lief als `nobody` und konnte die Schluesseldatei nicht lesen
  (`User=root`, Begruendung im Quadlet).
* GPU-Exporter 1.2.1 stuerzte mit dieser Treiberversion ab; 1.4.0 arbeitet sauber
  (115 Messwerte) und wurde in Betrieb genommen.
* Alloy sammelte keine Logs, weil Relabel-Regeln und Ziel-Labels fehlten.
* Die eigenen Host-Kennzahlen wurden von node_exporter verworfen, weil
  Typangaben fuer einige Familien fehlten; Assemble-Schritt ergaenzt sie jetzt.
* `start_units` blockierte bei fehlschlagenden Units (`--no-block` + Rueckmeldung).
* SMART meldete falsche Einheiten (1,2 TB statt 50 TB) und fehlende
  Temperaturwerte; JSON-Pfad berichtigt.
* Die Pruefung `47 --verify` meldete "nicht beschreibbar" auf einem rein
  lesenden Einhängepunkt; sie prueft jetzt Lesbarkeit und Inhalt.

Sicherheit und Zugangswerte:

* Alle Zugangswerte sind jetzt Zufallswerte ausserhalb von Git; die vier alten
  Standardpasswoerter sind aus dem Code entfernt, `make validate` prueft darauf.
* Wartungstunnel: nur noch ein eingetragener Schluessel statt ganz `~/.ssh`,
  kein Paketnachbau bei jedem Start, Platzhalterhost fuehrt zum Abbruch.
* Komodo-Periphery bricht ohne echten Server und Schluessel ab und erhaelt den
  Podman-Socket.
* Weltweit schreibbare Ordner (0777) durch 0755 mit Eigentruemer ersetzt.

Ausbau (fehlt in der Vorversion, im Masterprompt aber verlangt):

* node_exporter mit Host-Einhaengung, GPU-Exporter, eigener Kennzahlensammler
  inkl. systemd-Timer, SMART/NVMe-Werte.
* Vier eigene Dashboards (LLM-Betrieb, GPU, Host, Speicher) mit deutschen Titeln
  und menschenlesbaren Einheiten statt eines Panel-Rumpfes.
* Alarmregeln (`config/monitoring/alerts.yml`), inklusive Alarm auf fehlenden
  PLE-Eintrag im fstab.
* Benchmark misst Vorlaufzeit und Schreibrate getrennt, mit Warmup, echter
  Parallelitaet, GPU-Kontext, Geschichtsdatei und Sollwert-Pruefung.
* `scripts/backup.sh` und `scripts/restore.sh` mit Pruefsummen, pg_dump,
  ZFS-Snapshot und Testlauf.
* `scripts/doctor.sh` als gefuehrter Diagnose-Lauf (13 Pruefpunkte, jeweils mit
  dem naechsten Befehl), neue Einstiegspfade fuer alle Faelle.
* `scripts/wait-for-runtime.sh`, konfigurierbare Wartezeit statt starrer 15 Minuten.
* `scripts/check-drift.sh` plus GitHub-Actions-Workflow (validate, drift, Doku).
* Dokumentation: Duplikate mit Gross-/Kleinschreibung entfernt, mkdocs-Navigation
  repariert, ADRs 0009-0013 ergaenzt, neue Seiten `performance.md`,
  `backup-restore.md`, vollstaendige `monitoring.md`.
* Grundregel "die Grafikkarte gehoert dem Modell" (ADR 0013) dokumentiert.
* Messprotokoll zur Durchsatzfrage: 157,88 / 119,01 / 242,47 Token/s und die
  PCIe-Ursache (x4 @ 16 GT/s) statt Modell- oder GPU-Schuld.
