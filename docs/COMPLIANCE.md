# Abgleich mit dem Auftragstext (`setup_prompt.md`)

Der Auftragstext (42 Abschnitte plus Abschlusspruefung) ist die Anforderung,
dieses Repository die Umsetzung. Diese Datei haelt den Stand pro Abschnitt fest -
auch dort, wo bewusst abgewichen wurde. Zusaetzliche Regeln, die der Auftragstext
nicht kennt, stehen am Ende von `setup_prompt.md` (Abschnitt 43: Grundregel GPU,
Hinweis zu Vorlaufzeit gegen Schreibrate, Wartungstunnel standardmaessig aus).

Legende: **erfuellt** = umgesetzt und geprueft, **teilweise** = Umsetzung mit
dokumentierter Luecke, **zurueckgestellt** = bewusst spaeter.

| # | Abschnitt | Stand | Wo bzw. warum nicht |
|---|---|---|---|
| 1 | Zielarchitektur | erfuellt | README, `docs/architecture.md`, `versions.lock` |
| 2 | Architekturprinzip | erfuellt | Netze und Ablauf in `docs/architecture.md` |
| 3 | Preflight zuerst | erfuellt | `scripts/00-preflight.sh`, Bericht und Kurzfassung in `state/` |
| 4 | Repository-Struktur | erfuellt | wie verlangt, zusaetzlich `lib/units.sh`, `lib/secrets.sh`, `systemd/`, `containers/` |
| 5 | Pakete | erfuellt | `scripts/10-install-packages.sh` (deklarativ, idempotent) |
| 6 | Rootless Podman | erfuellt | `scripts/30-nvidia-podman.sh`; Linger, Socket, CDI-Neuerzeugung, GPU-Test |
| 7 | ZFS-Dataset | erfuellt | `scripts/20-zfs-setup.sh`; lz4, recordsize 1M, atime aus, ARC-Deckel |
| 8 | Modell herunterladen | erfuellt | `scripts/40-download-model.sh` (fortsetzbar), Pruefung `42-verify-model.sh` |
| 9 | Pennyroyal installieren | erfuellt | `scripts/50-install-pennyroyal.sh` mit Digest-Pinning |
| 10 | Baseline validieren | erfuellt | Health-Pruefung, Rauchtest in `setup-qwen-pennyroyal.sh`, API-Kette getestet |
| 11 | Online FP8 / Leistungsprofil | teilweise | Umgebungsvariable ist in der Unit durchreichbar (`PENNYROYAL_EXTRA_ENV=SGLANG_SM120_ONLINE_MXFP8=true`); Vorher/Nachher-Lauf steht aus | Experimenteller Schalter der Runtime; erst nach stabiler Baseline, Anleitung in `docs/performance.md` |
| 12 | SGLang-Metriken | erfuellt | `--enable-metrics` ist im Startskript gesetzt; `--enable-mfu-metrics` bewusst nicht (Kompatibilitaet ungeprueft) |
| 13 | Prometheus | erfuellt | laeuft rootless, Daten unter `~/.local/share`, Retention 30 Tage, Bindung `127.0.0.1:9090`, Config aus Git |
| 14 | OS-Metriken | erfuellt | node_exporter mit Host-Einhaengung; Dashboard "Host" mit CPU/RAM/Platte/Netz/PSI, Einheiten menschenlesbar |
| 15 | ZFS-UEberwachung | erfuellt | zfs-Collector plus eigene Pool-/Dataset-/Scrub-/ARC-Kennzahlen; Dashboard "Speicher" |
| 16 | SMART/NVMe | teilweise | Werte kommen aus dem Kennzahlensammler statt eines eigenen Exporters (kein zusaetzlicher Dienst); braucht sudo fuer die Messung, sonst `llm_smart_available 0` |
| 17 | GPU-UEberwachung | erfuellt | nvidia-smi-Exporter (1.4.0), 115 Messwerte; DCGM als Option vorbereitet (`GPU_EXPORTER=dcgm`) |
| 18 | Eigenes LLM-Dashboard | erfuellt | Dashboard "LLM-Betrieb" mit Bereichen Uebersicht, Latenz (TTFT P50/P95/P99, TPOT, Gesamt), Token, Cache; die vom Text genannten MFU/TFLOPS-Werte fehlen, weil dafuer ein ungepruefter Runtime-Schalter noetig waere |
| 19 | Grafana | erfuellt | Provisioning fuer Datenquellen und Dashboards, Passwort ausserhalb von Git |
| 20 | Loki und Alloy | erfuellt | sammelt alle Container-Logs (Label `container`), Zeitstempel werden ausgewertet |
| 21 | Dozzle | erfuellt | `quadlet/dozzle.container`, Port 8080 nur lokal |
| 22 | LiteLLM-Gateway | teilweise | laeuft, Key aus Secret, PostgreSQL angebunden; ein virtueller Schluessel pro Agent ist angelegt, aber noch nicht per Skript verwaltet |
| 23 | Secrets | teilweise | Auftragstext bevorzugt SOPS+age; umgesetzt ist der dort erlaubte Ausweichpfad `~/.config/llm-infra/*.env` (0600) plus Podman-Secret. `age` ist installiert, SOPS-Ablauf fehlt |
| 24 | Komodo | teilweise | Generator bricht ohne echten Server ab (kein Platzhalter-Autostart); Periphery braucht Podman-Socket, Aktivierung steht aus |
| 25 | GitOps-Ableitung | teilweise | Repo ist Quelle der Wahrheit, `make drift` erzwingt das; Komodo-GitOps wie im Text nicht aktiv |
| 26 | Nativer GitOps-Fallback | erfuellt | `scripts/gitops-deploy.sh` plus `systemd/llm-infra-deploy.service` und Timer (standardmaessig aus), bricht bei lokalem Dreck ab |
| 27 | Autossh | erfuellt | Standard aus, nur ein Schluessel im Container, kein `apk add` bei jedem Start, Verbindungstest `--check` |
| 28 | llmctl | erfuellt | `tui/llmctl.py` mit status/health/doctor/logs/deploy/benchmark/urls/backup/restore/credentials |
| 29 | Makefile | erfuellt | Selbsthilfe ueber `make`, alle Ablaeufe als Ziel |
| 30 | Healthchecks | teilweise | menschenlesbare Kurzpruefung plus grindlicher `doctor.sh`; ein echter Container-Healthcheck in der Unit ist vorbereitet, wirkt aber erst nach dem naechsten Runtime-Neustart |
| 31 | Benchmark | erfuellt | Vorlaufzeit und Schreibrate getrennt, Warmup, echte Parallelitaet, GPU-Kontext, Verlaufsdatei, Sollwert-Pruefung |
| 32 | Alarme | erfuellt | 22 Regeln in `config/monitoring/alerts.yml`; kein Alarm fuer kurze Einzelspitzen (alles mit `for`-Zeit) |
| 33 | README | erfuellt | Schnellstart, Tabellen, Grundregel |
| 34 | Versionspinnen | teilweise | alle Images mit fester Version, Runtime zusaetzlich mit Digest; kein signaturpruefender Download (cosign) |
| 35 | Sicherheit | teilweise | localhost-Bindung, rootless, Zufallspasswoerter, Secret-Guard; offene Punkte: eigenes Seccomp-Profil, HTTPS |
| 36 | Backup / Wiederherstellung | erfuellt | `scripts/backup.sh`, `scripts/restore.sh` mit Pruefsummen, pg_dump und ZFS-Snapshot |
| 37 | Spaetere Erweiterungen | zurueckgestellt | zweites Modell, Azure-Fallback, OpenTelemetry, Router: Architekturstelle vorbereitet, nichts installiert |
| 38 | Betriebsphilosophie | erfuellt | `AGENTS.md`, gefuehrter Betrieb ueber `doctor.sh` |
| 39 | Installationsreihenfolge | erfuellt | `docs/install.md` mit Dauern und Neustartstellen |
| 40 | Abschlusspruefung | siehe unten | |
| 41 | Arbeitsweise | erfuellt | Schritt fuer Schritt, commit je Phase |
| 42 | Git-/Dokumentationsregeln | teilweise | Alles als Code, Idempotenz, Doku je Feature, ADRs vorhanden (13); Vor-Ort-Beleg je Phase steht jeweils in `docs/status.md` |

## Abschlusspruefung (Abschnitt 40) im Wortlaut

| Pruefung | Stand | Wie nachpruefbar |
|---|---|---|
| 1. Dienste starten nach Neustart automatisch | teilweise | Units haben `WantedBy=default.target`, Linger ist an; der Punkt ist nach dem naechsten echten Neustart abzuhaken (`./scripts/doctor.sh`) |
| 2. `nvidia-smi` auf dem Host | erfuellt | `nvidia-smi -L` |
| 3. GPU im Container | erfuellt | `scripts/30-nvidia-podman.sh` (CUDA-Basisimage), plus laufende Runtime |
| 4. Modell auf ZFS mit lz4 | erfuellt | `zfs get compression <pool>/llm/models` |
| 5. Modell antwortet | erfuellt | Rauchtest in `state/api-smoke.json` |
| 6. OpenAI-API funktioniert | erfuellt | `curl .../v1/chat/completions` |
| 7. LiteLLM erreicht die Runtime | erfuellt | Gateway-Test ueber `:4000` |
| 8. Virtueller Schluessel funktioniert | teilweise | eingerichtet, aber ohne eigenen Test im Repo |
| 9. Direkter Runtime-Port nicht extern | erfuellt | `ss -lntup | grep 8001` zeigt nur 127.0.0.1 |
| 10. Prometheus-Targets oben | erfuellt | `curl :9090/api/v1/query?query=up` |
| 11. Hostmetriken im Dashboard | erfuellt | Dashboard "Host" |
| 12. GPU-Metriken im Dashboard | erfuellt | Dashboard "GPU" |
| 13. SGLang-Metriken im Dashboard | erfuellt | Dashboard "LLM-Betrieb" |
| 14. Token/s und Vorlaufzeit verstaendlich | erfuellt | Stat-Panels mit Einheiten s und Token/s |
| 15. ZFS/Speicher im Dashboard | erfuellt | Dashboard "Speicher" |
| 16. Loki hat Dienst-Protokolle | erfuellt | Logsuche `{container="pennyroyal"}` |
| 17. Dozzle zeigt Podman-Logs | erfuellt | http://127.0.0.1:8080 |
| 18. `llmctl status` | erfuellt | `./tui/llmctl.py status` |
| 19. `llmctl restart` | erfuellt | ruft `apply-runtime-unit.sh --restart-only` mit Schutz auf |
| 20. `llmctl logs` | erfuellt | `./tui/llmctl.py logs` |
| 21. `llmctl benchmark` | erfuellt | neue Messmethodik |
| 22. `make validate` fehlerfrei | erfuellt | laeuft auch in CI |
| 23. `make deploy` idempotent | erfuellt | zweiter Lauf ohne Aenderungen (`make drift` prueft das) |
| 24. Git ohne Geheimnisse | erfuellt | `make validate` plus `detect-secrets` |
| 25. Komodo auf Podman getestet | zurueckgestellt | wartet auf echten Server |
| 26. Autossh existiert, ist aber aus | erfuellt | Generator bricht ohne echten Rechner ab |
| 27. zweiter Deploy-Lauf ohne Dreck | erfuellt | Einheiten aus `lib/units.sh`, Altlasten werden entfernt |
| 28. README reicht nach Monaten | erfuellt | README plus `docs/operations.md` |

## Vom Auftragstext abweichende Regeln (mit Grund)

1. **Die Grafikkarte gehoert dem Modell.** Kein TP2, keine geteilte Nutzung, kein
   zweiter GPU-Nehmer. Begriff im Text ("Single-GPU-Betrieb") wird hier als
   harte Regel gelesen; siehe `docs/adr/0013-*.md`.
2. **Vorlaufzeit und Schreibrate werden getrennt gemessen.** Der Auftragstext
   nennt beide Begriffe, aber die alte Implementierung hat sie vermischt;
   seitdem sind die Zahlen nicht mehr direkt mit frueheren Messungen vergleichbar
   (`docs/performance.md`).
3. **Host-Metriken im Container statt nativ installiert.** Der Auftragstext
   erlaub beides; Entscheidung und Messtechnik in `docs/adr/0010-*.md`.
4. **Kein zusaetzlicher SMART-Exporter.** Gleiche Zielwerte aus dem
   Kennzahlensammler; Auftragstext erlaubt "wenn moeglich einfacher".
5. **Wartungstunnel standardmaessig aus und ohne Platzhalter-Autostart.**
   Ein Tunnel auf `example.net` waere eine dauernde Fehlerquelle gewesen.
6. **`setup.sh` ueberschreibt vorhandene Nutzerdateien nicht.** Der Auftragstext
   will Reproduzierbarkeit; ein ungefragtes Ueberschreiben von
   `~/.config/opencode/opencode.json` waere ein Datenverlust. Vorlage legt sich
   daneben.
