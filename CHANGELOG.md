# Aenderungsprotokoll
## 2026-11-16 (Runde: Sicherung meldet Teilfehler statt taetig zu sein)

- **Erstes Backup dieses Repos erstellt** und gepaeft: Archiv mit Konfiguration,
  Datenbank-Auszug und den drei Zustandsordnern (Chat, Grafana, Portal), Manifest mit
  Pruefsummen, `./scripts/restore.sh --list` zeigt es. Arztlauf Pruefpunkt 14 damit OK;
  Warnungen gesamt von vier auf **drei**.
- **Gefundener Defekt im Sicherungsskript:** der erste Lauf meldete „Backup fertig“
  bei Rueckgabewert 0, obwohl `tar` drei Grafana-Ordner nicht oeffnen konnte
  (`png/csv/pdf`, hoeren dem Container-Nutzer). Grund war dieselbe Befehlsketten-
  Falle wie anderswo: `[[ -d ]] && tar ... && log ...` loest kein `errexit` aus, weil
  nur der letzte Befehl der Kette massgeblich ist — und das war das `log`, das im
  Fehlerfall gar nicht lief. Eingebaut: ein Teilzaehler fuer Konfiguration, Datenbank
  und jeden Zustandsordner; Grafanas neu erzeugbare Ausfuhrordner sind jetzt
  ausgeschlossen und begruendet; bei mindestens einem fehlenden Teil endet der Lauf mit
  **Rueckgabewert 1**, roter Meldung und naechstem Befehl. Gegentestet mit einer
  unlesbaren Datei unter Wegwerf-`HOME`: Meldung „Backup unvollstaendig“ und rc=1.

## 2026-11-16 (Runde: Chat-Beweis ueber die Oberflaeche, Pruefpunkt Chat-Dienst)

- **Chat nach der Schluesselumstellung Ende-zu-Ende gemessen:** Anmeldung gegen
  `http://127.0.0.1:3001`, Anfrage uber die Oberflaeche, `POST /api/chat/completions`
  mit **HTTP 200**, angezeigte Modellantwort „Paris“, keine Konsolenfehler. Beweist,
  dass der Chat mit dem **eigenen** Schluessel antwortet (Helfer
  `/tmp/qa/chat-oberflaeche.mjs`).
- **Zwei Messfehler dieser Runde, beide meine:** der QA-Helfer las das Passwort als
  letztes Wort der Zugangszeile - die Zeile trug es aber nach dem Wort `passwort`,
  deshalb blieb die Anmeldemaske leer („Enter Your Password“). Der Helfer benutzt
  jetzt dieselbe Regel wie `chat_zugang()` in `scripts/60-install-open-webui.sh`.
  Zweiter Irrtum: ich hielt das Fehlen von `litellm_*`-Reihen in Prometheus fuer einen
  Defekt - es ist eine begruendete Entscheidung in `config/monitoring/prometheus.yml`
  (Chainguard-Image ohne `prometheus-client`, `/metrics` liefert 404; Anleitung zum
  Freischalten in `docs/monitoring.md`). Lebensdauer des Gateways wird ueber
  `llm_unit_active` gemessen; gemessen: **18 Einheiten melden 1**, darunter `litellm`.
- **Neuer Pruefpunkt 16 „Chat-Dienst“ in `scripts/doctor.sh`:** Unit laeuft,
  `/health` antwortet, und die Chat-Umgebung haelt einen **eigenen** Gateway-
  Schluessel. Der dritte Punkt ist die Sicherung der letzten Aenderung nach oben.
  Gegentestet in einer Wegwerf-Umgebung (`LLM_INFRA_SECRETS_DIR`): Master im Chat =
  FEHLER mit naechstem Befehl, fehlender Schluessel = FEHLER mit naechstem Befehl.
  Gesamtstand: **16 Pruefpunkte, 0 Fehler, 4 Warnungen**.


## 2026-11-16 (Runde: Chat ohne Master-Schluessel, Dashboard ohne No-Data, Diagnosefall Laufzeit)

- **Chat-Dienst ohne Master-Schluessel:** `open-webui.env` enthielt den
  Master-Schluessel des Gateways - der Chat haette damit Schluessel anlegen und
  loeschen koennen. `lib/secrets.sh` stellt jetzt ueber `chat_service_key()` einen
  eigenen Virtual Key aus (derselbe Speicher und dasselbe Skript wie die
  persoenlichen Schluessel, Alias `open-webui`); `scripts/rotate-secrets.sh` nutzt
  dieselbe Quelle statt den Master zu übernehmen. Gemessen: Schluessel gesetzt,
  Form `sk-…`, nicht identisch mit dem Master; Ausrolllauf meldet „model check: OK
  (13 Modelle gemeinsam mit dem Gateway)“ und „gateway Anbieter … HTTP 200“.
- **Eigenen Fehler behoben:** `chat_service_key()` schrieb seine Fortschrittszeile mit
  `log` auf Stdout; in der Befehlsersetzung wanderte die Zeile in den Wert, und die
  Datei bekam eine kaputte `OPENAI_API_KEY=`-Zeile (Logtext plus Schluessel in zwei
  Zeilen). Fortschritt geht jetzt nach Stderr, Fehlermeldungen auch - ein `die` in der
  Funktion haette nur die Untershell verlassen. Der dabei im Terminal sichtbar
  gewordene Schluessel wurde **gesperrt und neu ausgestellt** (`--revoke`, `--issue`).
- **Dashboard Speicher ohne No-Data-Panels:** 10 Panels hingen an Kennzahlenfamilien,
  die es auf diesem Rechner nicht gibt (`llm_zfs_*`, `node_zfs_*`, `llm_ple_*`). Sie
  liegen jetzt in einer zugeklappten Zeile miterklaerung, damit die Flaeche ohne
  „No data“ erscheint und die Panels auf Rechnern mit ZFS/PLE unveraendert liefern.
  Gemessen: Grafana provisioniert neu (version 4, 7 Panels), alle sichtbaren Panels
  mit Daten. Zwei Messfehler dieser Runde sind berichtigt: das Log-Panel haengt an
  Loki (nicht Prometheus) und fuehrt 14 Stroeme - es war nie leer.
- **Diagnosefall Laufzeit-Unit:** `scripts/doctor.sh` meldet jetzt WARNUNG, wenn der
  Inferenz-Container laeuft, aber keine Unit ihn verwaltet (`flash-next-v3` ist so ein
  Fall), plus Hinweis, dass `quadlet/` keine passende Unit beschreibt. Der Fall ist
  entscheidungsneutral: mit einer vorhandenen Unit schlaegt er in OK um.

## 2026-11-16 (Runde: Drift-Pruefung ohne Eingriff, Pennyroyal-Unit berichtigt)

- Fehler behoben: `scripts/check-drift.sh` liess die Generatoren im
  Arbeitsverzeichnis laufen und verglich danach mit `git diff`. Die Pruefung war damit
  selbst der Eingriff, den sie melden soll: nach jedem `make drift` lag eine geaenderte
  `quadlet/pennyroyal.container` im Baum, und `make ci` rollte bei dieser Gelegenheit
  Units aus (`render_unit` nach `~/.config/containers/systemd`, `daemon-reload`,
  `systemctl --user start`). Heute laufen die Generatoren in einer weggeworfenen
  `git worktree`-Kopfe des committeten Standes; die neue Drift-Kapsel in
  `lib/units.sh` (`LLM_DRIFT=1`) lenkt alle Ausroll-Schritte in einen leeren Ordner und
  verdeckt `systemctl`, weil einzelne Generatoren es direkt aufrufen. `--restore` ist
  weggefallen. Gemessen: `make drift` meldet die bekannte Pennyroyal-Abweichung weiter
  (`DRIFT GEFUNDEN`, Exit ungleich 0), Unit-Verzeichnis vor/nach dem Lauf identisch,
  kein Container neu gestartet, Arbeitsverzeichnis unveraendert.
- Eigener Fehler berichtigt: `88a95c8` hatte `quadlet/pennyroyal.container`
  mitgenommen, waehrend die alte Pruefung die Generatorfassung in den Baum schrieb -
  das Upstream-Bild stand im Repo statt der Fork-Fassung des Betreibers. Zurueck auf
  den Stand `e9085c6` (`localhost/flash-next-sm120:serving`, `093e2bf`).

## 2026-11-16 (Runde: Anleitung wieder bedient, Proxy-Pflichtpunkte)

- Fehler behoben: die TOOLS-Kachel **Agent-Anleitung** zeigte auf
  `https://homepage.localhost/anleitung/`, aber niemand bediente die Seite
  (`/anleitung/` = `308`, `/anleitung.html` = `404`). Auslieferung ueber den lokalen
  Proxy: neue `config/proxy/site/anleitung/index.html`, Bind in
  `scripts/74-setup-local-proxy.sh`, eigene `handle`-Blende in
  `config/proxy/Caddyfile.template` vor dem Portal. Gemessen: `200`, Titel
  `LUNI | Anleitung`, Kachelklick oeffnet `_blank` mit `200`, 0 externe Anfragen.
- Wiederhergestellt: der Windows-Schnellstart (drei Schritte, Virtual Key,
  `local-balanced`) stammt aus dem alten Bestand `luni-llmops-linux`, Zweig
  `fix/homepage-local-recovery`. Das ZIP-Paket bleibt ausserhalb dieses Repos
  (Zertifikate), verlinkt ist der Bestandsordner.
- Pflichtpunkte fuer den neuen Dienst `llm-proxy` nach `AGENTS.md`: Kennzahlen
  `llm_local_proxy_homepage_up` und `llm_local_proxy_grafana_up` ueber
  `scripts/collect-host-facts.sh` (die Caddy-Admin-API liefert `/metrics` nur auf
  ihrer eigenen Loopback-Schnittstelle; der Umweg ueber einen inneren Lauscher brachte
  `403` und ist zurueckgebaut) und ein Diagnosefall `Lokaler Zugang ueber Namen` in
  `scripts/doctor.sh` (Pruefpunkt 15, curl ohne `-k`, faengt also auch einen Verlust
  der CA-Verankerung).
- Dokumentiert: Zielkonflikt von `GF_SERVER_ROOT_URL=https://grafana.localhost/grafana/`
  (absolute Grafana-Links zeigen auf den benannten Namen, fuer die oeffentliche
  Azure-Flaeche nicht erreichbar) und der Befund, dass der Inferenz-Container
  `flash-next-v3` von keiner Unit verwaltet wird - offene Entscheidung des Betreibers.

## 2026-11-16 (Runde: Portal auf 2.6.0 - Tabs und lokale Symbole)

- Fehler behoben: `scripts/60-install-homepage.sh` erzeugte die Unit nur im
  Repo und kopierte die Konfiguration nach `~/.config/llm-infra/homepage`,
  installierte sie aber nie nach `~/.config/containers/systemd` - der
  Live-Container hing deshalb auf v2.4.0 fest, obwohl `versions.lock` und
  Generator laengst 2.6.0 zeigten. Der Installer nutzt jetzt denselben
  Mechanismus wie alle anderen Dienste: `install_units`/`systemd_reload`/
  `start_units` aus `lib/units.sh`; ein Neustart faellt nur bei Abweichung
  von Unit-Datei oder laufendem Bild (gemessen: zweiter Lauf ohne Neustart).
- Der `--check`-Pfad prueft seiteneffektfrei (Generatorausgabe per Pipe
  vergleichen statt die committete Datei zurueckzuschreiben) und
  ueberlebt den frueher todbringenden Bildvergleich: `podman images | awk`
  brach mit SIGPIPE + `pipefail` still den Lauf ab (rc 141). Neu im --check:
  installierte Unit gegen Repo-Fassung (`installed_unit_diff`).
- Umstieg v2.4.0 -> v2.6.0 (Digest-Pin aus `versions.lock`,
  `sha256:3e38fe78…`): erst 2.6.0 kennt Tabs und indexiert `/app/public`
  beim Start. Die sechs Tabs aus `config/homepage/settings.yaml` (Dashboard,
  LLM, INFRA, SYSTEM, BETRIEB, TOOLS) sind gemessen klickbar. Symbole
  versioniert unter `config/homepage/icons/`, dateiweise read-only nach
  `/app/public/icons/` eingebunden; ein Verzeichnis-Bind auf `/app/public`
  als Ganzes schattiert die Locales ab (Rohschluessel im Text) und ist
  deshalb falsch.
- Gemessene Abnahme (2026-11-16): `podman ps` zeigt das Digest-Bild; alle
  16 `/icons/<datei>` liefern 200; `--check` rc=0; `https://homepage.localhost/`
  200; Playwright ueber `https://homepage.localhost/`: 633 Anfragen, nur
  `homepage.localhost` und `grafana.localhost` (beide ::1), 0 an
  `cdn.jsdelivr.net` oder andere externe Hosts, 0 HTTP-Fehler; Screens
  `/tmp/qa/screens/portal-260-*.png`. `make validate` OK;
  `./scripts/healthcheck.sh` SYSTEM HEALTHY; `./scripts/doctor.sh`
  15 Pruefpunkte, 0 Fehler; `make drift` haelt an der bekannten Sperre
  ungecommitteter Generatordateien (offener Punkt 17 in `docs/HANDOFF.md`).

## 2026-11-16 (Runde: lokaler HTTPS-Zugang ueber Namen, Grafana ohne Anmeldung)

- Neuer verwalteter lokaler Proxy: `quadlet/llm-proxy.container` (Caddy,
  Netz `llm-observability`, nur `127.0.0.1:443`) mit Generator
  `scripts/74-setup-local-proxy.sh` (`make local-proxy`; Modi `--check`,
  `--render` fuer `make drift`, `--ca-import`, `--status`) und Vorlage
  `config/proxy/Caddyfile.template`. Er bedient
  `https://homepage.localhost/` (Portal) und
  `https://grafana.localhost/grafana/` (Grafana, Unterpfad bleibt).
  Warum Netz statt Loopback: rootless pasta reicht `127.0.0.1` nicht an
  Container durch, der Proxy proxen gegen `llm-homepage:3000` und
  `grafana:3000` (Namen mit `getent hosts` im Netz gemessen). `caddy validate`
  laeuft vor jedem Ausrollen; die Admin-API bleibt auf Container-Loopback.
- Port 443 rootless: Generator legt idempotent
  `/etc/sysctl.d/99-llm-infra-local-proxy.conf` an und senkt
  `net.ipv4.ip_unprivileged_port_start` auf 443 (sudo, reversibel; bewusst
  nicht 80). Caddy-CA ins Systemtrust: `--ca-import` (trust anchor +
  update-ca-trust); danach curl ohne `-k` und Browser ohne Warnung - gemessen.
- Portal-Hostfreigabe: `HOMEPAGE_ALLOWED_HOSTS` in `config/host.env` um
  `homepage.localhost` ergaenzt (Generator `scripts/60-install-homepage.sh`,
  Default nachgezogen); bestehende Loopback-Formen bleiben.
- Grafana ohne Anmeldung: `scripts/60-install-monitoring.sh` schreibt jetzt
  vollstaendig `GF_SERVER_ROOT_URL=https://grafana.localhost/grafana/`,
  `GF_SERVER_SERVE_FROM_SUB_PATH=true`, anonyme Lese-Rolle (`Viewer`),
  `GF_AUTH_DISABLE_LOGIN_FORM=true` und `GF_SECURITY_ALLOW_EMBEDDING=true`
  nach `~/.config/llm-infra/grafana.env` (Vorlage neu dokumentiert);
  Abweichung wird mit Zeitstempel-Sicherung neu geschrieben, `--check`
  prueft die Schluessel. Noetig war zusaetzlich, die
  `Environment=GF_AUTH_ANONYMOUS_ENABLED=false`-Zeile aus
  `quadlet/grafana.container` zu entfernen: podman laesst `--env` gegen
  `--env-file` gewinnen - vorher blieb alles beim 302 auf `/grafana/login`
  (gemessen), die Dateiwerte waren wirkungslos.
- Gemessene Abnahme (2026-11-16): beide Namen 200 ohne `-k`; `/grafana/` ohne
  Login-Formular und ohne 301 auf Azure; `d-solo?panelId=2` liefert fuer alle
  fuenf Dashboards 200 ohne Cookies und ohne `X-Frame-Options: deny`;
  oeffentlich bleiben `/grafana/` 401 und `/v1/models` 401 (anonym reicht
  nicht nach aussen, Basic-Auth sitzt vor); `./scripts/healthcheck.sh` SYSTEM
  HEALTHY; `make validate` OK; `--check` beider Generatoren gruen.
- Neustarts nur `grafana.service`, `homepage.service` und der neue
  `llm-proxy.service`; vorab Inflight-Check (litellm-Journal, Runtime-Logs:
  null Anfragen), `flash-next-v3` nicht beruehrt.
- Symbol-Aufraeumen: PNG-Garnitur unter `config/homepage/public/icons/`
  wirkungslos fuer v2.4.0 (Aufloesung nur ueber CDN; im Bild unter `/app`
  nachgesehen) und geloescht; CDN-Abhaengigkeit als bekannter Mangel in
  `docs/HANDOFF.md` (Zielbild: lokale SVG ueber `/images/custom/-Bind-Mount`).

## 2026-11-16 – Oeffentlicher Zugang, Alarmweg, Beobachtungskorrektur

- Chat-Oberflaeche (Open WebUI) zum ersten Mal von Hand bis zur Antwort
  geprueft, und vier Daengel am richtigen Ort behoben. Befund vor der
  Korrektur: die eigene Datenbank der App enthielt null Konten bei gleich-
  zeitig offener Registrierung (der erste Browser-Besuch waere Administrator
  geworden), der Ollama-Anbieter stand an und hing an `host.docker.internal:11434`
  (dort hoert nichts - nachgewiesen mit Verbindungsverweigerung), es gab kein
  Standardmodell, und der Update-Hinweis legte beim ersten Oeffnen ein modales
  Fenster ueber die Seite, das jeden Klick blockierte. Die Werte durften nicht
  nur in `open-webui.env` stehen: die App uebernimmt Umgebungswerte nur fuer
  Schluessel, die in ihrer Datenbank noch fehlen (`Config.seed_defaults`), ein
  Austausch in der Datei wirkt auf eine bestehende Installation nicht.
  `scripts/60-install-open-webui.sh` kann deshalb mehr als die Unit schreiben:
  `--provision` setzt Anbieter, Standardmodell und Registrierung ueber
  dieselben Endpunkte, die auch die Verwaltungsoberflaeche benutzt, und
  `--check` (ohne Seitenwirkung) prueft zehn Punkte und endet mit dem
  naechsten Befehl. Der Neustart des Chat-Dienstes ist ein eigener, erklarter
  Schritt und bricht ab, wenn das Journal in den letzten zwei Minuten
  Chat-Anfragen zeigt (`--forzieren` fuer die bewusste Ausnahme). Nachweis des
  Weges: echte Frage an `qwen3.8-flash-next`, Antworttext im Browser
  verglichen, gateway-seitig `POST /v1/chat/completions 200 OK` im Journal von
  `litellm.service` zur Sekunde der Anfrage.
- Doppelung zurueckgenommen: das Administratorkonto gehoert zu
  `scripts/64-setup-open-webui-account.sh`, nicht in die Umgebungsdatei. Die
  beiden `WEBUI_ADMIN_*`-Zeilen sind aus `lib/secrets.sh` entfernt, das
  Konto-Skript ist der einzige Schreibende der Zugangszeile, und
  `60-install-open-webui.sh` ruft es nur auf. Fruehere Fassungen der Zeile
  (`Benutzer … Passwort …`) werden uebernommen, aber nur nach gelungener
  Anmeldung und nur in diesem Skript. `lib/secrets.sh` erzeugt
  `open-webui.env` weiterhin selbst: Vorher-Sicherung bei Aenderung, kein
  Schreiben und keine Sicherung ohne Aenderung, kein Wert auf dem Bildschirm.
- `quadlet/open-webui.container` ist unveraendert: der Generator erzeugt die
  committete Datei byte-identisch (`git diff` dazu bleibt leer). `make drift`
  bleibt aus dem bekannten pennyroyal-Grund rot, unveraendert.
- Offen und dokumentiert: die Administratoren-Verstellungen zeigen rohe
  Uebersetzungsschluessel, weil das Bild kein `i18n/` mitbringt; und der
  Gateway-Zugang der App ist der Masterschluessel, ein eigener Schluessel waere
  die sauberere Endfassung (`./scripts/71-gateway-keys.sh --issue open-webui`).

- Irrtum zurueckgenommen: die entfernte
  `ExecStartPre=%h/forge/watchdog/reference-start-gate.sh` war nicht der Grund fuer
  rotes `make drift`. Die committete Referenz-Unit weicht in Bild, `Description`,
  `Ulimit`-Zeilen und Modellpfad von der Generator-Ausgabe ab; die Zeile ist wieder drin.
  Welche Fassung die Referenz ist, entscheidet der Betreiber (siehe `docs/HANDOFF.md`).
- Neuer Pfad fuer die Chat-Oberflaeche: `scripts/64-setup-open-webui-account.sh` legt das
  erste Open-WebUI-Konto an (es wird Administrator), erzeugt den Zugangswert, schreibt ihn
  in `~/.config/llm-infra/credentials.txt` (0600, mit Zeitstempel-Sicherung der Datei) und
  prueft die Anmeldung gegen `POST /api/v1/auths/signin`. Idempotent, `--check` ohne
  Seitenwirkung, der Wert wird nie ausgegeben. Getesteter Ist-Zustand: App auf
  127.0.0.1:3001, `/api/models` antwortet erst nach Anmeldung (401 vorher), Umleitung
  nach `/auth` wie erwartet; Grafana auf 127.0.0.1:3000 leitet auf die oeffentliche
  `/grafana/`-Adresse um (Wurzel-URL, kein Defekt).
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
