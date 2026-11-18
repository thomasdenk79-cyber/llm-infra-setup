# Review-Befunde 2026-11-18 (zwei Agenten je Pod, read-only)

Methode: pro Pod zwei unabhängige Agenten - A = Konfiguration+Version,
B = Betrieb+Sicherheit. JSON-Befunde mit Beleg; jeder Befund nach Pruefung
durch den Betreiber-Agenten entweder behoben (mit Commit), als bewusst
akzeptiert dokumentiert oder hier als offen abgelegt. Live-Nebelkerzen
(Dozzle ohne Anmeldung, Alertmanager ohne Empfaenger, Pennyroyal-Fork) sind
dokumentierte Betreiberentscheidungen und zaehlen nicht als Befund.

Legende: [x] behoben und verifiziert, [~] dokumentiert/abgewogen, [ ] offen.

## alertmanager
- A: [x] Live-Konfiguration hatte den KI-Empfaenger nie geladen (POST /-/reload,
  idempotenter Reload-Schritt im Installer, Unit in start_units).
  [x] Aktivierungsweg im 80-Skript war Noop. [x] Lock-Digest war Config-Id
  (Manifest-Digest 45c3a586). [x] Meta-Wchter uebersah vier Jobs.
  [x] AlarmwegFehlt-Summary gegenlaeufig. [x] Quadlet-Kommentar mit Regelzahl.
- B: [x] Prometheus-Token enthaelt Master-Key statt read-only — dokumentiert
  ([~] HANDOFF-Restliste); [x] api_key-Literal in litellm.yaml -> os.environ.

## alloy
- A: [x] Journal-Schiene lief auf retireden flash-next-v3 -> qwen38-rc2 plus
  Referenzquelle, keep-Regex angepasst, max_age 30m -> 2h. [x] Positionsdatei
  fehlte (Named-Volume, Installer legt 473:473 vor). [~] tote
  Docker-Discovery-Ziele (Upstream-Eigenheit, Journal ist Lehrpfad).
- B: [x] Erster Start gegen frisches Volume crashte sechsmal (Vorbesitz im
  Installer). [x] kein Doctor/Healthcheck-Fall fuer die Alarmkette.

## dozzle
- A: [x] LAN-Zugangszeilen ausser Betrieb dokumentiert (host.env). [x] Digest
  fehlte im Lock (86fc4ecb). [x] LogQL-Beispiele in der Doku falsch.
- B: sauber (leere Befundliste).

## grafana
- A: [x] Explore-Seite fuer Viewer geoeffnet (GF_USERS_VIEWERS_CAN_EDIT),
  Digest nachgezogen (5749a0e9), Dashboard-QA-Script gegen Panel-Fehler.
- B: [x] healthcheck/Doctor-Loecher (beide erweitert); [~] anonyme
  Query-Moeglichkeit ueber Loopback ist Freigabefolge (in docs/monitoring.md
  festgehalten, an der Freigabe nichts geaendert).

## homepage
- A: [x] SERVICE-STATUS fehlte im layout; die versprochene bidirektionale
  Pruefung existierte nicht (settings.yaml-Kommentar log) — Pruefung live in
  validate.sh eingebaut, layout ergaenzt. [x] widgets.yaml nannte v2.4.0.
  [x] Ungecommitteter Lock-Stand (Grundregel 0) — Serie von Checkpoints.
- B: [x] Crashloop-Obergrenze/Healthcheck-Abdeckung; Doctor- und
  Healthcheck-Faelle ergaenzt; StartLimits-Betrachtung dokumentiert.

## incident-agent
- A: [x] Demo-Query nutzte nicht existente Spalten (zustand/eta_minuten ->
  phase/eta_art). [x] State-Verzeichnis 0755 -> 0700 inkl. chmod. [~]
  Bild-Digest aus lokalem Podman-Zustand statt Gegenprobe gegen Lock.
  [~] SECRETS_DIR-Variablen untersuetzt, Heredoc hartkodiert (Default-Pfad
  in Betrieb, kein Fehlerfall aktiv).
- B: [~] /webhook und /replay unauthentifiziert (nur Stack-Netze, als
  LAB-Zustand dokumentiert). [x] Doctor-Fall fehlt (Target-Pruefung ueber
  Prometheus eingebaut). [~] Phasenliste nennt acknowledged/mitigating, die
  der Ablauf nie vergibt. [~] journald-Abwesenheit der Agent-Ausgaben.

## litellm (Gateway)
- A: [x] Lock beschrieb falsche Laufzeit (SGLang-Bestand nachgezogen, host.env
  und versions.lock jetzt deckungsgleich mit qwen38-rc2). [x] Runtime bindet
  0.0.0.0:30000 — Betreiberentscheidung, HANDOFF-Punkt 1. [x] bonsai ohne
  Umgebungsvariablen (Installer-Defaults). [x] api_key-Literal -> env.
  [x] litellm-Digest war Config-Id (RepoDigest 60947db0). [~] Modellname
  qwen3.8-flash-next vs. /models/qwen38 gleicht nur SGLang-Grosszugigkeit aus.
- B: [x] Failover-Kette bricht an fehlendem BONSAI_BASE_URL ab (Installer
  setzt Defaults auf unerreicherbaren Host, Kette faellt sauber durch).
  [x] Drill-Skript regexte auf pennyroyal-Bild (auf aktuellen Stand gestellt).
  [x] Lesbarkeit Zugangsdateien/0600 bestaetigt sauber.

## litellm-postgres
- A: [x] Kein Digest-Pin (9a70e4d1 nachgezogen, Generator liest Lock).
  [x] Generator-Doppelquelle Version. [~] 16.4 ist hinter 16.16 —
  Betreiberentscheidung Neustartfenster (Lock-Kommentar). [x] Kein
  Backup-Timer (llm-backup.{service,timer}, taeglich 03:10, Persistent,
  --install/Doctor-Fall/MONITOR_TIMERS). [x] Irritierender Logtext zur
  env-Datei (lib/secrets.sh erzeugt sie automatisch).
- B: [x] Superuser-Rolle und offene pg_hba dokumentiert und auf die
  Betreiberliste gesetzt (Hartung braucht Migrationsfenster); [x] lokales
  trust innerhalb des Behalters als LAB-Zustand aufgenommen; [x] Backup-Archive
  jetzt 0600 (chmod in backup.sh, Bestand nachgezogen); [~] PublishPort 5432
  kann weg, wenn kein Wartungswerkzeug ihn braucht (Betreiber); [~]
  shared_buffers 128 MB undCheckpoint-Druck: Neustartfenster; [~]
  Benutzerjournal-Retention ~70 min behindert Restartforensik (Hostthema);
  [x] Tabellenname LiteLLM_VerificationToken fuer kindliche Pruefungen notiert.

## gpu-exporter
- A: [x] Kein Digest, Generator ignorierte Lock (beides gefixt, --check
  neu). [x] Image-Referenz auf schwebendem Tag. [~] dcgm-Zweig wuerde
  Prometheus-Job stumm schalten (Port 9400 vs. 9835) — im Skript kommentiert.
  [~] CDI-Specs ausserhalb Git (Betriebsumstand).
- B: [x] Doctor-Fall fehlte (9835/Metriken-Sonde eingebaut). [~] GPU 86 Grad
  unter Last bei 88-Grad-Schwelle — Beobachtungspunkt Betreiber.

## node-exporter
- A: [x] Kein Digest (065914c0 gemessen und gesetzt). [x] Hostname war
  Container-Id (--hostname ueber PodmanArgs). [x] ZFS-Collector No-op
  (entfernt, Doku). [x] /etc/hostname-Zeile in filesystem-Tafel (Exclude
  erweitert). [x] Selbst-Wants in zwei Service-Vorlagen geloescht.
  [x] Netzwerk nur Containersicht — Kommentar und docs/monitoring.md ehrlich.
  [~] Abwesenheitsalarme fuer PLE/ZFS-Serien (Gate des Collectors laesst
  keinen sauberen PromQL-Gegenpart zu).
- B: [x] HOCH: StatussammlungSteht war blind (sticky Textfile, absent() feuerte
  nie) — echter Herzschlag llm_stack_status_timestamp_seconds + time()-Alarm.
  [x] stack-status-Timer fehlte in MONITOR_TIMERS und Doctor-Schleife.
  [~] timer last-run-Erfolg nur ueber is-active (kein ExecMainStatus-Messwert).

## cadvisor
- A: [x] Netz-je-Unit war advertised, liefert aber null Serien (rootless) —
  Generator-Kopf, AGENTS.md-Tabelle und Dashboard-Reihe berichtigt,
  BeobachtungsdatenFehlen-Alarm als Netz ueber die Relabel-Annahmen.
  [x] Kein Digest (448ca9b1). [x] Kommentierte Portzahl widersprach Unit.
  [x] "nichts beschreibbar" ohne --read-only (Kommentar abgeschwaecht).
- B: [x] HOCH: Installer liess daemon-reload weg — Ursache der 13:48-Episode
  (66 und 60 jetzt mit Reload). [x] Doctor/Healthcheck-Faelle. [x] machine-id
  fehlte im Bild (Read-only-Mount, Journal-Rauschen 288/Tag weg).
  [~] Runtime qwen38-rc2 erhaelt kein unit-Label (Doku-Absatz).
  [~] OOM-Series wegen /dev/kmsg leer (Doku; Journal/Pipelinedeck).
  [~] pid=host-Restrisiko dokumentiert (yama-Abschwaermung belegt).

## loki
- A: [x] retention_period fehlte (30d gesetzt, Compactor-Logik erklaert).
  [x] creation_grace_period liess spaet ankommende Batches verwerfen (2h —
  Verwerfungen nach Restart auf Null gemessen). [x] Digest fehlte (d0a95e65).
  [~] Aufnahmelimits auf Defaults (4 MB/s global,足够了 fuer einen Host).
- B: [x] 9160er-Diskard-Zaehler hatte keine Alarmierung (ProtokollverlustBeiLoki).
  [x] Doctor/Healthcheck-Loecher. [~] auth_enabled=false nur durch Loopback
  geschuetzt (LAB-Entscheidung wie Dozzle).

## prometheus
- A: [x] HOCH: Regel-Nachladeverzug — Reload in den Ablauf aufgenommen,
  /api/v1/rules vergleicht jetzt Disk- und Prozessstand. [x] Uncommittete
  Regeln (Checkpoint-Serie). [~] prometheus_image_digest fehlt noch (nur Tag).
  [x] Unit-Kommentar nannte pennyroyal:8001 statt aktiven vllm-Pfad.
- B: [x] Kein Diagnosefall fuer die Alarmkette (Doctor-Block: Alertmanager,
  Alloy, Loki-Fluss, Incident-Target, Exporter, Portal, Readiness).
  [x] NRestarts-Einordnung (Journal, kein Befund).

## open-webui
- A: [x] Kein Digest-Pin (332438e0) — Generator liest Lock. [x] HOCH Wertig:
  rotate-secrets.sh schrieb abweichende env mit ENABLE_SIGNUP=true und ohne
  die vier Absicherungen — Vorlage an lib/secrets.sh angeglichen. [x] Passworte
  im Prozessbaum (64-Skript: curl-Koerper jetzt 077-temp-Datei, Muster
  chat_post). [x] Ungecommitteter Lock.
- B: [x] healthcheck ohne Chat-Fall (ergaenzt). [x] Wants=litellm fehlte.
  [~] forwarded-allow-ips '*' (Loopback-Publish begrenzt Risiko).
  [~] 629 MB Auslagerung der UI ist Normalbetrieb (beobachtet).

## llm-proxy (Caddy)
- A: [x] caddy_wiki_digest war Config-Id statt Manifest (fc9cbc10 korrigiert,
  Art im Kommentar benannt); [x] caddy_proxy-Eintrag fehlt im Lock (angelegt,
  Generator liest jetzt Lock plus validate prueft Digester gegen RepoDigests).
  [~] littlem-Tippfehler bleibt Alias (Bestandsschutz, in HANDOFF vermerkt).
  [~] vereinzelter DNS-Aussetzer (1 in 7 Tagen). [x] Zertifikats-Ablaufalarm
  ueber llm_caddy_cert_min_expiry_seconds (Collector + Regel, Schwellwert eine
  Stunde unter dem Erneuerungsfusspunkt). [x] HSTS und Headerbereinigung,
  [x] Access-Log fuer die offenen LAN-Sites, [x] HealthCmd.
  [~] rate_limit: die Caddy-Fassung dieses Builds kennt die Richtlinie nicht -
  BRockade fehlt damit bewusst (HANDOFF-Restliste).
- B: laeuft noch.

## wiki
- A: [x] Digest-Pin fehlt im Generator (liest jetzt versions.lock, live mit
  Manifest fc9cbc10); [x] fehlerhafte Rebuildpfade endeten mit Erfolg (venv/
  mkdocs fehlen => Exit 1 mit Naechstbefehl, Repo fehlt => bewusst still);
  [x] Build ueberschrieb das Auslieferverzeichnis (jetzt atomar ueber
  site/.build-<sha> + current-Symlink, Caddy haengt am Parent); [x] Stempel
  .built-sha lag im Ausliefer-Root (nach ausserhalb verlegt, hide-Regel
  zusatzlich); [x] WIKI_DIR als Rechnervariable (host.env-Konvention);
  [x] Doctor-Fall (HTTP, Groesse, Stempel gegen HEAD, Timer-Result);
  [x] pip-Pin: docs_tooling bleibt massgeblich, venv-Neubau folgt der Vorlage.
  [~] 30-Minuten-Schleife prueft nur die Commit-Sha (Arbeitsbaumaenderungen
  bewusst ausserhalb - der Timer soll keine Schmutzstaende bauen).
- B: [x] Access-Nachweis des Rebuildpfads (einmal --force gefahren, Journal
  belegt 'Wiki neu gebaut'); [x] HealthCmd fehlt (eingebaut, healthy);
  [x] keine Diagnoseabdeckung fuer :3003 (Doctor + Healthcheck);
  [~] Benutzerjournal nur ~70 min (Hostthema, siehe postgres);
  [~] Bild caddy:2.8 im Bestand ohne Verbraucher - Entfernen ist
  Betreiberaktion; [~] Auslieferung aus dem Git-Arbeitsbaum statt
  ~/.local/share (mit Atomar-Bau entschärft, Umzug offen).

## llm-nginx (existiert nicht - auditiert: Web-Stufe und Weiterleiter)
- A: [x] Pod 'llm-nginx' ist eine Scheinreferenz (kein Objekt; Audit galt
  llm-proxy/llm-wiki — Orga-Korrektur); [x] Forensik um den Poller
  10.89.2.48: es war die Loopback-Lebenszig-Probe des Gateway-Wachters mit
  rootlessport-SNAT, kein Fremdzugriff; [x] Access-Log des Proxies fehlte
  (jetzt fuer die offenen Sites); [x] HealthCmd; [x] Digester der Web-Stufe
  (validate-Gegenprobe); [HOCH, fremd] luni-caddy (caddy:2.8, 0.0.0.0:8443,
  Bind ~/LUNI-P0-V3) hoert nicht auf dieses Repo - Besitzerrepo muss heben,
  in der HANDOFF-Restliste. [x] Zugriffszahlung des vLLM-Weiterleiters
  (Journal), [~] Authentifizierung des Weiterleiters bleibt Betreiberfrage.
- B: [x] dieselbe POLLER-Aufloesung; [x] vier 'wilde' sglang-Container sind
  Kurzzeit-Probes einer externen Entwicklungspipeline auf diesem Rechner
  (--rm, ohne GPU, kein Grund zum Eingreifen); [~] direct-llm ohne Schluessel
  im LAN wie dokumentiert, jetzt mit Zaehlung; [x] littlem-Alias dokumentiert.
