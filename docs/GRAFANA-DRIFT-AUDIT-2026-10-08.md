# Grafana-Drift-Audit 2026-10-08 — Warum verhindert Git diese Drift nicht?

**Status:** Analyse-Dokument, bewusst uncommitted (Audit-Lauf eines zweiten Agenten;
der Fix selbst liegt in `f83bd7c`). Kein Befund hier ist eine bereits umgesetzte Änderung.

**Auslöser:** Grafana zeigte 0 Daten in allen Panels, obwohl `/targets` vollständig grün war.
Nutzerfrage: *„Wir wollten doch alles im Git für sauberen Wiederaufbau — wie konnte DAS passieren?“*

---

## 1. Kurzfassung der Antwort

Das Git-Setup ist **konfigurations-zentriert**, nicht **wirkungs-zentriert**. Es sichert ab,
dass Dateien im Repo den Generator-Auswurf exakt reproduzieren (`make drift`) und dass diese
Dateien syntaktisch sauber sind (`make validate`). Es prüft an keiner Stelle, ob die Konfig
**im Zusammenspiel zur Laufzeit Daten liefert**: kein DNS-Alias-Nachweis, kein Abgleich der
Dashboard-Datenquellen-UIDs gegen `datasources.yml`, keine einzige Panel-Abfrage gegen einen
laufenden Prometheus. Der Fehler steckte *selbst committed* im Repo — `prometheus.container`
ohne `NetworkAlias=prometheus`, während `datasources.yml` auf `http://prometheus:9090` zeigt.
Beides für sich valide; nur die **Querverbindung** war nie Gegenstand einer Prüfung. Zusätzlich
war die still fehlgeschlagene Passwort-Rotation (`grafana` vs. `systemd-grafana`) ein zweiter
Fall derselben Klasse: der Skriptpfad war versioniert, sein **Effekt** wurde nie verifiziert.

## 2. Verifizierter Ist-Zustand (2026-10-08, ~11:50 MESZ)

### Infrastruktur

| Prüfung | Ergebnis |
|---|---|
| `/api/v1/targets` | 5/5 activeTargets `up` (gpu, loki, node, pennyroyal, prometheus), 0 dropped |
| Grafana `/api/health` | ok, v12.1.1, database ok |
| Liveness | grafana:200, prometheus:200, litellm:200 |
| Grafana-Log letzte 2h | **0×** `lookup`/`no such host` (vor dem Fix: permanente DNS-Fehler) |
| Prometheus 24h | 122× `/api/v1/query`, 369× `/api/v1/query_range`, **keine 4xx/5xx-Fehlerserien** |
| Fix `f83bd7c` | auf `origin/main` (nachweislich via `git branch -a --contains`), HEAD `6db44fd` |

### Panel-Abfragen gegen den laufenden Prometheus (instant, eval now)

Alle 4 provisionierten JSONs wurden direkt aus dem Repo gelesen (der Mount ist identisch mit
dem Container-Inhalt; `/api/dashboards/uid/…` wurde nicht benötigt — Admin-Zugang nur als
Podman-Secret vorhanden, nicht als Datei unter `~/.config/llm-infra/`, das ist eine dokumentierte
Grenze dieses Audits; die DB-Inspektion der sqlite im Grafana-Volume diente als Ersatz).

| Dashboard | Queries | mit Daten | leer | Fehler |
|---|---:|---:|---:|---:|
| 01-llm-betrieb | 33 | 31 | 2 | 0 |
| 02-gpu | 22 | 20 | 2 | 0 |
| 03-host | 21 | 20 | 1 | 0 |
| 04-speicher | 19 | 8 | 11 | 0 |
| **Summe** | **95** | **79** | **16** | **0** |

79/95 deckt sich exakt mit der im Fix-Commit behaupteten Zahl. Die 3 Loki-Log-Panels liefern
per `query_range` Ströme (instant-Queries von Loki abgelehnt, aber Grafana-Log-Panels nutzen
Range — verifiziert über Loki-API direkt: `{container="pennyroyal"}`, `{container=~"pennyroyal|llm-gpu-exporter"}`,
`{job="containerlogs"}` alle mit Daten).

**Die 16 leeren Panels sind KEINE Drift, sondern dokumentierte Umgebungsgrenze WSL**
(Datengrenze-Textpanel in `04-speicher.json`): `node_zfs_*`, `llm_zfs_*`, `llm_smart_*`,
`node_cpu_scaling_frequency_hertz` und `llm_ple_backing_bytes` existieren in WSL nicht
(ZFS-VHD ohne SMART; node-exporter hat zwar `--collector.zfs`, aber es gibt kein ZFS im Kernel;
cpufreq-Collector ohne Host-Zugriff leer). Bestätigt: keine einzige `zfs`-Metrik in der TSDB,
nur `llm_smart_available`, `llm_ple_in_fstab/mounted` aus dem textfile-Collector.
**Eine echte Lücke zusätzlich zu den 3 Log-Panels:** Panel „Modell und PLE auf der Platte“
(id 61422) — `llm_model_shard_files`/`llm_model_incomplete_files` existieren, aber
`llm_ple_backing_bytes` collectet `collect-host-facts.sh` nicht → Panel bleibt auch auf dem
echten Host halb leer. Das ist ein Sammler-Fehlstand, kein WSL-Problem.

## 3. Root-Cause-Kette (Warum Git das nicht sah)

1. **Alias fehlte im Git, nicht in der Runtime.** `quadlet/prometheus.container` hatte vor
   `f83bd7c` kein `NetworkAlias` (per `git show f83bd7c~1` verifiziert: 0 Treffer), während
   `datasources.yml` seit jeher `http://prometheus:9090` vorsah. Der Zwischenzustand mit von
   Hand ergänztem Alias in der installierten Unit wäre *Drift gewesen* — so war der bug selbst
   versionierter Sollzustand. → **`make drift` kann keinen logischen Bruch finden, nur
   Generator↔Repo-Textbruch.**
2. **UID-Chaos war committed.** `datasources.yml` ließ `uid` weg → Grafana vergab Zufalls-UIDs
   in der DB; die Dashboards referenzierten `"uid": "prometheus"` als UID-Wert (14× in 03-host
   vor dem Fix). `validate.sh` prüft Dashboard-JSON auf `panels`/`uid`/`targets`-Vorhandensein —
   **nicht** darauf, dass referenzierte Datasource-UIDs in `datasources.yml` existieren.
3. **Panel-Metriken wurden nie gegen den Katalog geprüft.** `llm_pce_*`/`llm_pcie_*` (sysfs,
   in WSL nie vorhanden) standen monatelang committed im Repo.
4. **rotate-secrets.sh mit falschem Containernamen.** `podman exec grafana` statt
   `systemd-grafana` (Quadlet erzeugt `systemd-%N`) → schlug **still** fehl; credentials.txt,
   Podman-Secret und sqlite-DB drifteten unbemerkt auseinander. Dazu Grafana-12-Politik,
   die reine Hex-Passwörter ablehnt. Niemand hatte den Erfolg des Skripts je verifiziert.

**Gemeinsamer Nenner:** Das Repo validiert Artefakte statisch; die Kanten *Konfig→DNS*,
*Dashboard→Datasource-UID*, *Panel→Metrik-Katalog*, *Skript→Runtime-Effekt* sind unvalidiert.

## 4. Git-vs-Runtime-Matrix

| Schicht | versioniert? | validiert? | Lücke |
|---|---|---|---|
| Quadlet-Units (Repo `quadlet/`) | ✅ | ✅ `make drift` (nur Generatorschaften; Grafana/Prometheus/Loki sind handgepflegt und werden von drift **nicht** abgedeckt — der Test prüft nur, ob *generierte* Dateien sich nach Generatorlauf ändern) | ❌ Inhaltliche Querschnittsprüfung (Alias↔URL) fehlt |
| Installierte Units `~/.config/containers/systemd/` | ❌ (Derivat mit aufgelöstem `@CONFIG_ROOT@`) | indirekt | Manuelle Editierungen dort fallen nie auf |
| `datasources.yml` / `dashboards.yml` / Dashboard-JSONs | ✅ | nur Syntax + „Panels nicht leer“ | ❌ UID-Referenzen, ❌ PromQL gegen Metrik-Katalog |
| Provider `allowUiUpdates:false` + `updateIntervalSeconds:30` | ✅ (war schon vor dem Fix korrekt!) | — | ✅ UI-Kanalisierung greift: DB zeigt genau die 4 provisionierten Dashboards, alle mit `dashboard_provisioning`-Eintrag und Reconcile-Zeitstempel |
| Grafana-sqlite (`~/.local/share/llm-infra/grafana/`) | ❌ | ❌ | Datasource-Zufalls-UIDs, Ordner, Nutzer, Preferences; Alerting derzeit leer (0 Regeln) — **aber: jede UI-Alarmlage wäre flüchtig und beim Wiederaufbau weg** |
| Alerting/Notification-Provisioning (`provisioning/alerting`, `provisioning/plugins`) | ❌ existiert nicht im Repo | — | Grafana-Log meldet beim Start: Verzeichnisse fehlen (derzeit harmlos, da keine Alerts — strukturell aber eine Lücke) |
| Secrets (`~/.config/llm-infra/`, Podman-Secrets) | bewusst ❌ | nur Muster-Scan in validate | ❌ Konsistenz DB↔Secret↔credentials.txt ungeprüft (Fall 4) |
| Host-Facts-Textfile (`collect-host-facts.sh` → node-exporter) | ✅ Skript | ❌ | ❌ Abgleich Dashboard-Metriknamen ↔ `emit`ten Namen fehlt (Fund: `llm_ple_backing_bytes`) |
| Prometheus-Scrape-Targets (litellm deaktiviert, Kommentar im Repo) | ✅ | ✅ promtool (nur Syntax) | litellm-Gateway hat **keinen** Metrics-Job → Dashboard-01-Gateway-Panels hängen an Textfile/Postgres-Metriken, nicht an LiteLLm-Selbstinks |
| CI | — | ❌ keine `.github/workflows/`; `make ci` = validate+drift+docs-build, lokal, manuell | alles obige |

## 5. Maßnahmen (Vorschlag, nichts davon umgesetzt)

| # | Maßnahme | Wirkung | Aufwand |
|---|---|---|---|
| M1 | **Query-Smoke-Test** `scripts/smoke-dashboards.py`: jede Panel-`expr` (Prometheus) gegen `/api/v1/query` und jede Log-`expr` gegen Loki `query_range`; leere Treffer nur gegen Whitliste dokumentierter WSL-Grenzen (`zfs_*`, `smart_*`, `cpu_scaling`, …) erlaubt | findet **exakt** die Klassen Fall 1+3+ple-Panel; genau der Audit-Lauf dieses Dokuments, als Code | ~½ Tag |
| M2 | **UID-Konsistenz-Check in `validate.sh`**: referenzierte `datasource.uid`-Werte aller Dashboards müssen in `datasources.yml` vorkommen (rein statisch, CI-tauglich, kein laufender Stack nötig) | findet Fall 2 offline; billiger als M1, überlappend | ~1 h |
| M3 | **DNS-Kanten-Test in `doctor.sh`**: `podman exec systemd-grafana wget -qO- http://prometheus:9090/-/healthy` + Loki analog | findet Fall 1 zur Laufzeit, auch wenn Units handeditiert wurden | ~30 min |
| M4 | **`check-drift.sh` erweitern**: zusätzlich Soll↔Ist der *installierten* Units gegen `@CONFIG_ROOT@`-auflösten Repo-Stand prüfen (erfasst handgepflegte Units wie grafana/prometheus/loki, die der Generatorpfad nicht abdeckt) | schließt die „runtime editiert, Git weiß nichts“-Lücke | ~2 h |
| M5 | **Netzwerk-Kanten-Doku/Regel in `lib/units.sh`**: Kommentar+Konvention „jeder Container, dessen Name in `config/monitoring/*` als Host vorkommt, braucht `NetworkAlias=<name>`“; optional Alias↔URL-Abgleich als Mini-Check in validate | Fall 1 wurde zum Fix committet — künftig greift Regel+Check | ~1 h (Doku) + 1 h (Check) |
| M6 | **Effekt-Verifikation in `rotate-secrets.sh`**: nach `podman exec` Erfolg auslesen (z. B. Login-Versuch gegen `/api/login` oder DB-Query), bei Misserfolg Exit≠0; Containernamen aus `UNIT_DIR`-Konvention (`systemd-grafana`) ableiten statt hartkodieren | Fall 4: kein stiller Fehlschlag mehr | ~2 h |
| M7 | **Grafana-Startup-Lärm senken + Alerting-Provisioning anlegen**: leere `provisioning/{alerting,plugins}`-Verzeichnisse committen (beseitigt die beiden level=error-Zeilen im Startlog) und künftige Alerts **nur** als versionierte Files bereitstellen | verhindert „Alerts leben nur in der sqlite“-Drift | ~1 h |
| M8 | **`llm_ple_backing_bytes` in `collect-host-facts.sh` sammeln** (oder Panel-Umbau auf vorhandene `llm_ple_mounted` + du-Größe) | schließt die einzige nicht-WSL-bedingte Datenlücke (Panel 61422) | ~1 h |
| M9 | (optional) **journald-Wächter**: Rule/Alarm, wenn Grafana-Log `no such host|lookup` enthält (z. B. Loki-Rule + Alerting-File, passend zu M7) | reaktive Sicherheitsnetz für die ganze Fehlerklasse | ~2 h |

Empfohlene Reihenfolge: **M2 → M1 → M3** (deckt 90 % der beobachteten Klassen), dann M4/M6,
restlich bei Gelegenheit.

## 6. Grenzen dieses Audits

- Grafana-API nur ohne Auth geprüft (`/api/health`); Dashboard-Inhalt aus den Repo-/Mount-JSONs
  (identischer Inhalt, da read-only-Mount + `allowUiUpdates:false`; bestätigt durch die 4
  `dashboard_provisioning`-Zeilen in der sqlite). Ein UI-editierter Zustand *trotz* Provider
  wäre so nicht sichtbar — nach DB-Bestand (id 2–5, updated_by=-1) liegt keiner vor.
- Kein Passwort/Token ausgegeben oder geraten; `credentials.txt` existiert unter
  `~/.config/llm-infra/` (0600), wurde nicht gelesen.
- Instant-Prüfung `eval time=now`; Panels mit `rate(...[Xm])` auf gerade hochgefahrenen Containern
  (litellm 21 min) koennten sporadisch duenn gefuellt sein — kein Befund, nur Messmethode.
