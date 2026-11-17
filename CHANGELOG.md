# Aenderungsprotokoll
## 2026-11-17 (Windows-Launcher fuer verwaltete PowerShell-Richtlinien)

- **Einfacherer Start:** `Install.cmd` fragt nach Bestaetigung, entfernt den
  Internet-Zonenmarker nur von den mitgelieferten PowerShell-Dateien und startet
  den Installer. Es aendert keine Execution Policy und funktioniert mit der
  verwalteten `RemoteSigned`-Richtlinie; `AllSigned`/`Restricted` bleibt Aufgabe
  der IT. Die Key-Eingabe erklaert jetzt ausdruecklich, dass sie unsichtbar bleibt.
- **Weniger Einstiegsskripte:** OpenCode und Copilot nutzen denselben
  `Run-LocalLlm.ps1`-Wrapper; die zwei `.cmd`-Starter waehlen nur noch den Client.
  Die Anleitungsseite zeigt die SHA-256-Pruefsumme des ZIPs.

## 2026-11-17 (Kollegenpaket fuer lokale LLM-Routen und Dozzle ohne Anmeldung)

- **Kollegenpaket:** `make windows-client-package` erstellt
  `config/proxy/site/anleitung/anleitung.zip` reproduzierbar. Das Paket richtet
  ausschliesslich `local-*`-Modelle ueber `https://littlem.cachyos-x8664/v1`
  ein; weder Azure/oeffentlicher Tunnel noch `standard-*`-Modelle oder
  Zugangsschluessel liegen darin. Der Installer verifiziert den Fingerabdruck
  des lokalen Caddy-Roots, fragt einen persoenlichen LiteLLM-Virtual-Key ab,
  speichert ihn mit DPAPI und konfiguriert OpenCode sowie Copilot CLI.
- **Dozzle:** lokale Proxy-Anmeldung entfernt; Route bleibt auf das
  vertrauenswuerdige private LAN beschraenkt und wird ohne Zugangsdaten mit
  HTTP 200 geprueft. Alte, genau benannte Dozzle-Credential-Dateien werden beim
  Ausrollen entfernt.
- **Dokumentation und Bootstrap:** die Anleitung ist unter `/anleitung/`
  erreichbar; der HTTP-Bootstrap liefert nur das oeffentliche Caddy-Root und
  `anleitung.zip`, alle anderen Pfade bleiben 404.

## 2026-11-17 (Betreiberentscheidung: direct-llm ohne Zugangsdaten)

- `direct-llm` leitet `/v1/*` direkt an den vLLM-Weiterleiter und verlangt
  absichtlich weder Basic-Auth noch einen API-Schluessel. Der private
  `LAN_BIND_IPS`-Bereich ist die Zugangsgrenze; LiteLLM (`littlem` und
  `llm-direct`) behaelt seine eigene Bearer-Key-Pruefung. Der Proxy-Generator
  entfernt beim Ausrollen alte `direct-llm`-Zugangswerte; Basic-Auth bleibt
  ausschliesslich fuer Dozzle.
- Handover-, Sicherheits- und Diagnosehinweise auf das Verhalten ohne Anmeldung
  angepasst. Der Proxy wurde ausgerollt und `--check` war erfolgreich;
  Windows-Routenchecks liefen mit `curl.exe --ssl-no-revoke` erfolgreich.
  Die erste Messung mit TLS-Fehlern bleibt als behobene Abweichung im
  Abnahmebericht dokumentiert.

## 2026-11-17 (Runde: Namensaufloesung im Netz - ein Handgriff, nicht sechs)

- **Neu: `scripts/75-setup-local-dns.sh`** (und `make local-dns`). Die sechs
  LAN-Namen gab es in keinem DNS, deshalb hing jedes Geraet an einer
  hosts-Datei. Der Generator schreibt `/etc/llm-infra/dnsmasq/lan-zone.conf`
  und haengt sie dem Paket-Dienst per Drop-in
  `/etc/systemd/system/dnsmasq.service.d/99-llm-infra.conf` an - das Arch-Paket
  liefert kein `/etc/dnsmasq.d` und seine `conf-dir`-Zeile ist auskommentiert,
  deshalb `--conf-file` statt einer Datei im Paketordner, und `--enable-dbus`
  bleibt stehen, weil die Einheit `Type=dbus` ist. Ein `address=/`-Eintrag
  antwortet auf jeden Namen unter `.<LAN_DOMAIN>`; `no-resolv` und
  `bind-interfaces` mit `listen-address` nur auf `LAN_BIND_IPS` halten den Dienst
  klein (Gegengeprueft: `example.com` bleibt leer, `ss -lun` kennt nur
  `192.168.0.198:53`, die Host-Aufloesung ueber `systemd-resolved` unveraendert).
  Bewusst kein mDNS: `.local` wuerde alle Zertifikatsnamen und
  `HOMEPAGE_ALLOWED_HOSTS` aendern.
- **Wurzelzertifikat ohne SSH holen:** der Proxy bedient auf Hafen **8081**
  genau einen Pfad `GET /caddy-local-authority-root.crt` (plain HTTP, alles
  andere 404). Damit entfaellt `scp` samt Passwort auf dem Windows-Geraet; die
  Datei ist nur der oeffentliche Schluessel, die Echtheit prueft der
  Fingerprint aus `--ca-export`. Bewusst 8081 und nicht 80: die Kernelgrenze
  `net.ipv4.ip_unprivileged_port_start=443` laesst rootless kein 80 (Gemessen:
  `rootlessport cannot expose privileged port 80`, die Unit fiel aus), und 8080
  ist als Loopback-only-Hafen reserviert. `--windows-setup` nutzt den neuen Weg.
- **Suchendungen konfigurierbar (`LAN_DNS_SUFFIXES`):** Windows haengt an
  zweiteilige Namen die vom Router verteilte Domain an, `homepage.<LAN_DOMAIN>.lan`
  liegt damit ausserhalb der Zone und wandert zum Router. Der Generator kann
  weitere `address=`-Zeilen erzeugen; `--check` prueft jede genannte Endung
  mit. Leer laesst die Zone exakt wie zuvor (Standard). Am Geraet zeigt
  `nslookup -debug`, welche Namen wirklich geschickt werden - deshalb steht der
  Befehl jetzt auch in `handover/WIN-LAN-TODO.md`.
- **Abnahme:** `--check` rc=0 fuer beide Generatoren, Arztlauf ohne Fehler,
  HTTPS-Routen unveraendert (Portal 200). Das Windows-Notebook bleibt offen
  (HANDOFF Nr. 18), weil von diesem Rechner aus nicht pruefbar.

## 2026-11-17 (Runde: Notebook-Abnahme - ein Block statt Handarbeit)

- **Neuer Modus `--windows-setup`:** der Generator gibt den kompletten
  PowerShell-Block fuer das Windows-Notebook aus - hosts-Zeile, `Test-NetConnection`
  gegen 443, `scp` der Wurzel, `certutil -dump` mit dem erwarteten SHA-256-
  Fingerabdruck, `certutil -addstore` und alle sechs Routen gegen ihre erwarteten
  Codes. Bislang waren dafuer zwei Doku-Abschnitte und Handarbeit noetig; ein
  vertippter Pfad oder ein nicht vergleichener Fingerabdruck war die haeufigste
  Ursache fuer "Name wird nicht aufgeloest". Ausgabe enthaelt keine
  Zugangswerte (Gegengeprueft gegen `lan-credentials.txt`).
- **Messung zur Abnahme:** Firewall war nie der Grund - `sudo ufw status numbered`
  zeigt `443/tcp ALLOW IN 192.168.0.0/24` (Regel 5, Gepflegt von
  `workstation-setup`), und der Zaehler derselben Regel belegt angekommene
  LAN-Pakete. `--check` rc=0, Listener auf `192.168.0.198:443`, TLS-Kette validiert
  gegen das exportierte Wurzelzertifikat. Fehlend war ausschliesslich die
  hosts-Datei des Geraets (fuer diese Namen gibt es kein DNS). Pruefschritte in
  `docs/troubleshooting.md` ergaenzt ("Name loest auf einem Fremdgeraet nicht
  auf", "Verbindung laeuft in Zeit").

## 2026-11-17 (Runde: Deep-Review mit vier Gegenpruefern, drei stille Defekte)

- **Stiller Defekt 1 - Proxy lud die alte Konfiguration:** `write_if_changed`
  ersetzte Dateien ueber `install` (neuer Inode), der haelt das Caddyfile aber als
  Einzel-Datei-Bindung im Container. Jeder Reload nach einer reinen
  Caddyfile-Aenderung lud stillschweigend die alten Seiten; weder `--check` noch
  `make drift` sahen das. Beweis: Host-Inode 919969 (5723 B) gegen
  Container-Inode 918478 (5324 B). Der Generator ueberschreibt bestehende Dateien
  jetzt in ihrer Inode, vergleicht vor dem Neustart die laufende Fassung und
  `--check` meldet die Abweichung mit dem naechsten Befehl. Gegenprobe eingebaut:
  veraltete Container-Fassung liefert `FEHLT` und rc=1, nach dem Ausrollen wieder
  rc=0.
- **Stiller Defekt 2 - Prometheus ohne Reload:** das Quadlet hatte weder
  `ExecReload` noch eine Reload-Moeglichkeit und montierte `prometheus.yml` und
  `alerts.yml` als Einzeldateien (nach `git pull` haette der Container die alte
  Fassung gehalten). Neu: Ordnermount nach `/etc/prometheus/conf`,
  `ExecReload=/usr/bin/podman kill --signal HUP systemd-%N`, Wege in
  `validate.sh` und Doku nachgezogen. Eigenfehler der Runde dokumentiert:
  `--config.reload.interval` existiert bei Prometheus v3.5 nicht und brachte die
  Unit in eine Crash-Schleife - entfernt, Reload ist SIGHUP.
- **Stiller Defekt 3 - Grafana warf LAN-Besucher auf den Loopback:**
  `https://grafana.cachyos-x8664/login` antwortete `301 ->
  https://grafana.localhost/grafana/login` (root_url), ein Geraet aus dem LAN
  landete ins Leere. Die Route setzt die `Location` jetzt auf den Namen der
  Anfrage; Loopback unveraendert (beides gemessen).
- **Metrikziel fuer den Proxy (AGENTS.md-Regel):** neuer Job `caddy` gegen
  `llm-proxy:8080`, der nur `/metrics` auf den Caddy-Admin-Endpunkt durchreicht
  (ohne `header_up Host 127.0.0.1:2019` antwortet der Admin-API 403). gemessen:
  Target up, 10 Serien mit `caddy_`-Praefix.
- **Weiterleiter aus dem WLAN gezogen:** `auto` band bisher jede Schnittstelle,
  auch `192.168.0.47` (wlan0), und bot dort die Modell-API ohne Zugangswert.
  Neu bindet `auto` Loopback, die Adresse der bevorzugten Standard-Route und die
  Podman-Gateways; `VLLM_PUBLIC_BIND=all` stellt den alten Zustand her.
  Gegenbeweis gegen den Review-Vorschlag "nur Loopback plus Gateways": dabei
  fielen `up{job="vllm"}` von 1 auf 0 und `direct-llm` auf 502, weil Gateways im
  Host-Namespace nicht bindbar sind. Regressionslauf
  `./scripts/test-vllm-forwarder.sh` bleibt gruen. Weiterer Weg in
  `docs/HANDOFF.md` Nr. 19.
- **Haerte im Prueflauf:** `--check` prueft beide Basic-Auth-Faelle inklusive
  bewusst falschem Passwort, `LOOPBACK_ONLY_PORTS` waechst um 3003, 9100, 12345
  und 8120, `--ca-export` zeigt den SHA-256-Fingerabdruck der Wurzel mit
  `certutil`-Gegprobe, und `check-drift.sh` vergleicht jetzt auch
  `config/proxy/Caddyfile` (bislang unprueft).
- **Betrieb:** `sudo loginctl enable-linger` gesetzt - der Benutzermanager und
  damit der ganze Stapel starten ohne Desktop-Anmeldung (war die Voraussetzung
  von `scripts/30-nvidia-podman.sh`, wurde aber nie gesetzt). Der Arztlauf
  empfiehlt `make podman` nur noch mit dem Hinweis, dass die GPU der Laufzeit
  gehoert (AGENTS.md Regel 2).
- **Praxisnebenwirkung:** die Gegenpruefer loeschten die
  `/etc/hosts`-Eintraege fuer die LAN-Namen; wiederhergestellt aus
  `./scripts/74-setup-local-proxy.sh --print-hosts`. Sitzungsunterlagen unter
  `.omo-work/` sind jetzt gitignore- und scan-ausgenommen, weil sie Attrappen von
  Zugangswerten enthalten koennen (`validate.sh` lief deshalb rot).
- **Belege der Runde:** `--check` rc=0, `./scripts/doctor.sh` 18 Pruefpunkte
  0 Fehler, `./scripts/validate.sh` rc=0, Prometheus up (`vllm`, `caddy`,
  `grafana`), `https://direct-llm.cachyos-x8664/v1/models` 401 ohne / 200 mit
  Zugang, 401 mit falschem Passwort.

## 2026-11-17 (Runde: Doku-Deckung eng und Zahlen-Nachpruefung)

- **Englisches Spiegel-Ensemble auf Stand gebracht:** `docs/en/index.md`
  beschrieb noch die WSL-Zeit (Pennyroyal auf 8001, ZFS "in Betrieb"); es zeigt
  jetzt die laufende Fassung (vLLM `flash-next-v3` 30000, Weiterleiter 30001,
  Gateway v1.105.0, Beobachtungsstapel inklusive Alertmanager 9093) und die
  HTTPS-Einstiege. Neu `docs/en/lan-access.md`: Adressen, Schutzmodell,
  Windows-11-Client (Hilfsskript und Handweg), Rueckbau und Befehlsliste -
  eigenstaendige englische Fassung, kein Duplikat der deutschen Abschnitte.
  `docs/en/operations.md` nennt jetzt die echten Logquellen (unmanaged
  Runtime-Container, User-Units) und verweist auf die LAN-Seite.
  `mkdocs.yml` fuehrt die neue Seite in der nav.
- **Zahlen gegen Messung gezogen (2026-11-17):** Dashboard-Abfragen 121 -> 120
  (`grep -o '"expr"' ... | wc -l`); die "drei Panels ohne Anfrage" in
  `05-agent-observatorium.json` sind seit `5fa6ab0` behoben, `validate.sh`
  meldet keine mehr; `llm_unit_active`zaehlt jetzt 19 von 20 Serien mit Wert 1
  (neu dabei `llm-proxy`, `wiki`; `pennyroyal` meldet bewusst 0). Belege:
  `docs/status.md`.
- **CMDB berichtigt:** `docs/cmdb.yaml` fuehrte LiteLLM als v1.101.0, gemessen
  und gepinnt ist v1.105.0 (`versions.lock`, `quadlet/litellm.container`);
  Dienstkarte `local-proxy` verweist bei `docs`/`next` jetzt auf das
  Windows-Hilfsskript und die Abnahme (HANDOFF Nr. 18).
- **Uebergabe entstaubt:** `docs/HANDOFF.md` - Datum auf 2026-11-17, Loopback-
  Proxy-Punkt nicht mehr als "nur 127.0.0.1" (der LAN-Ausbau steht im naechsten
  Punkt), Dashboard-Zaehlung vereinheitlicht, offene Punkte 5-8 auf den
  heutigen Stand geschrieben (README ist sauber; Chat-Konto vorhanden und
  Anmeldung gemessen; beide Waechter-Timer installiert), Nr. 18 nennt das
  PowerShell-Hilfsskript als Kuerzesten Weg; Nummernhinweis 9-14 ergaenzt.
- **Unabhaengig nachgemessen:** `--check` rc=0, alle LAN-Codes wie dokumentiert
  (200/401/403), oeffentlich 200/401 am Azure-Gateway, Doctor 17 Pruefpunkte
  0 Fehler, `validate.sh` OK, `make docs-build` (mkdocs --strict) durch.
  Befehle: siehe `docs/HANDOFF.md` Abschnitt 3.

## 2026-11-17 (Runde: LAN-HTTPS fuer den Windows-Arbeitsplatz)

Offene Aufgabe aus `.omo-work/todo-local-llm-network.md`; Zugangsvoraussetzung
(Qwen3.8-Fork laeuft, GPU-Rauchtest bestanden) war erfuellt - Laufzeit
`flash-next-v3` antwortet auf `127.0.0.1:30000/v1/models` mit 200.

- **Neu ausgerichtet statt provisorisch:** der LAN-Teil haengt jetzt an
  `config/host.env` (`LAN_BIND_IPS`, `LAN_DOMAIN`, `LAN_DOZZLE_USER`,
  `LAN_DIRECT_LLM_USER`, `VLLM_FORWARD_PORT`) statt an einer einzelnen
  Datei unter `~/.config/llm-infra`. Die alte Datei wird weiter gelesen, wenn
  `host.env` nichts sagt, damit ein bereits eingerichteter Rechner nicht
  stehen bleibt. `make drift` bleibt dicht: die Bedingungen stehen nur im
  Generator, die committeten Dateien sind sein Ergebnis.
- **Sieben LAN-Routen** in `config/proxy/Caddyfile.template` (Vorlage) bzw.
  `config/proxy/Caddyfile`: `homepage`, `grafana`, `littlem` (Gateway),
  `llm-direct` (Alias), `dozzle`, `direct-llm` (vLLM ueber den Weiterleiter)
  auf `.<LAN_DOMAIN>` plus eine Fallback-Site, die unbekannte Namen mit 403
  abweist statt an ein Backend weiterzureichen. Ohne `LAN_BIND_IPS` faellt der
  ganze Block weg - dann enthaelt das Caddyfile nichts, was ins Netz zeigt.
- **Basic-Auth nur wo es noetig ist:** Dozzle und `direct-llm` (stromaufwaerts
  ohne Anmeldung) hinter bcrypt; LiteLLM nicht, weil es seine Virtual-Keys
  selbst prueft (401 ohne Schluessel). Hashes in
  `~/.config/llm-infra/proxy/lan-auth.env`, lesbare Werte in
  `lan-credentials.txt`, beide 0600 und ausserhalb von Git; im Caddyfile stehen
  nur `{env.*}`-Platzhalter. Erzeugt mit `caddy hash-password` aus dem
  gepinnten Bild, idempotent (vorhandene Hashes bleiben).
- **Zwei Fehler der Provisorien behoben:** (1) beide Routen teilten sich den
  Benutzernamen `operator`, die Zugangsdatei war aber nach Benutzerenschluessel
  abgelegt - der zweite Zugang bekam den ersten Wert (401 trotz richtigem
  Passwort). Abgelegt wird jetzt nach Rolle (`LLM_LAN_DOZZLE_PASSWORD`,
  `LLM_LAN_DIRECT_LLM_PASSWORD`), und ein geaenderter Benutzername in
  `config/host.env` erzeugt gezielt einen neuen Zugang. (2) Der Generator
  startete den Container bei jedem Lauf neu, weil die Unit kein `ExecReload`
  hatte; jetzt laedt Caddy ueber `podman exec ... caddy reload` nach, ein
  Neustart bleibt nur bei Port-, Netz- oder Umgebungsaenderungen.
- **Neue Betriebsmodi** in `scripts/74-setup-local-proxy.sh`: `--plan`
  (Unterschiede zeigen, nichts aendern), `--ca-export` (CA-Datei,
  Windows-Befehle, Fingerprint), `--print-hosts` (Zeile fuer
  `C:\Windows\System32\drivers\etc\hosts`), `--lan-credentials` (Pfade ohne
  Werte). `--check` prueft zusaetzlich jeden LAN-Namen mit `--resolve`, die
  401/200-Paare der Basic-Auth-Routen, den 403-Fallback und die
  Loopback-Ausschliesslichkeit von elf Backend-Ports.
- **Gemessen 2026-11-17:** alle sechs LAN-Adressen wie erwartet (200 bzw. 401
  ohne Zugangswerte), `direct-llm` liefert die echte Modelliste, ueber
  `littlem` ein vollstaendiger `chat/completions`-Durchlauf mit
  `qwen3.8-flash-next` (HTTP 200, Modelltext), Loopback unveraendert 200,
  unbekannter Name ohne Backend-Kontakt, oeffentlich weiterhin 200/401 am
  Azure-Gateway. `./scripts/74-setup-local-proxy.sh --check` endet mit rc=0,
  `make validate` und `make drift` bleiben gruen.
- **Doku nachgezogen:** `docs/operations.md` (Abschnitte LAN-Zugang, Windows 11
  mit hosts-Datei und Root-Import, Rueckbau, Fehlerbilder, Tunnel-Lebensdauer),
  `docs/status.md` (gemessener Stand), `docs/cmdb.yaml` (Dienstkarte
  `local-proxy`), `config/host.env.example` (neue Variablen).
- **Offen:** die Windows-Seite am Geraet. Befehle sind dokumentiert
  (`--print-hosts`, `--ca-export`, `certutil`), die Abnahme am PC steht aus.

## 2026-11-16 (Runde: Referenz-Unit nahm beim Login die Grafikkarte)

- **Gefunden beim Blick auf den naechsten Hochlauf:** `render_unit()` in
  `lib/units.sh` setzte jede installierte Unit auf Autostart - auch
  `pennyroyal.container`. Die Datei liegt in `~/.config/containers/systemd/` und war
  in `default.target.wants` verlinkt, ihr Bild `localhost/flash-next-sm120:serving`
  existiert aber nicht (`podman image exists` = nein). Beim naechsten Login waere eine
  Unit mit `Restart=on-failure` (30 s) endlos fehlgeschlagen, und mit vorhandenem Bild
  waere ein zweiter GPU-Container angelaufen - beides gegen die Regeln des Repos.
- **Behoben an der Ursache:** Autostart folgt jetzt der Unit-Datei - `render_unit()`
  setzt den `.wants`-Verweis nur bei vorhandener `WantedBy=`-Zeile und entfernt einen
  alten Verweis sonst. Die Referenz-Unit verliert in `scripts/50-install-pennyroyal.sh`
  (und damit in `quadlet/pennyroyal.container`) ihr `[Install]`-Stueck: sie bleibt
  installiert und ist mit `systemctl --user start pennyroyal.service` startbar.
- **Gemessen nach dem Einbau:** `pennyroyal verlinkt: 0`, `flash-next verlinkt: 1`
  (die Laufzeit laeuft also weiterhin beim Login an), Laeufer unveraendert
  `flash-next-v3 Up 13 hours`, nichts gestartet.
- **Nebenbefund behoben:** die Ausgabe von `apply-runtime-unit.sh --install-only` /
  `--dry-run` empfahl `systemctl --user start pennyroyal.service`, weil
  `laufzeit_bestimmen` nur im Neustart- und Uebernahmezweig lief und sonst der
  Altwert `pennyroyal` stand. Der Aufruf steht jetzt auch im Anwendzweig; die Ausgabe
  nennt korrekt: "Laufzeit-Unit am ContainerNamen erkannt: flash-next".



## 2026-11-16 (Runde: Warten auf Leerlauf wird ein Werkzeug)

- **Neu `scripts/takeover-when-idle.sh` mit Timer.** Die Uebernahme des von Hand
  gestarteten Containers durch `flash-next.service` haengt an einer Bedingung, die man
  nicht bestellen kann: null laufende Anfragen. Der Timer
  `llm-runtime-takeover.timer` (2 Minuten) misst die Anfragezahl dreimal
  hintereinander und meldet Uebernahmebereitschaft in
  `state/runtime-takeover/bereits.txt`; der Befehl dazu steht in der Meldung.
  Neustarten tut er standardmaessig nicht (`LLM_TAKEOVER_AUTOMATIK=0`) - die Regel
  "eigener, angekuendigter Schritt" gilt auch einem Timer nicht. Mit Automatik ruft er
  `apply-runtime-unit.sh --takeover`, das die Zahl erneut prueft; nach Erfolg waehlt
  sich der Timer selbst ab.
- **Beide Pfade gemessen:** ohne Messquelle `unbekannt` -> Zaehler bleibt 0 (kein
  Handeln); kiinstliche Nullmessung -> `1/3, 2/3, 3/3`, Bereitschaftsdatei, kein
  Neustart. Der Takt ist aus Prometheus abgeleitet, nicht geraten: ueber 13 Stunden
  waren 42 % der Messpunkte null, die kuerzesten zusammenhaengenden Fenster 20
  Minuten - ein Zehn-Minuten-Takt haette sie nie gesehen. Unit-Vorlagen liegen in
  `systemd/llm-runtime-takeover.{service,timer}`.
- Doku: neuer Abschnitt "Uebernahme der Laufzeit bei Leerlauf" in
  `docs/operations.md`, Skriptkarte in `AGENTS.md`.



## 2026-11-16 (Runde: Rueckgabepfad, der wirklich zur Sicherung passt)

- **Der Rueckgabeweg war gegen das eigene Sicherungsarchiv kaputt.** `extract()` in
  `scripts/restore.sh` setzte voraus, dass der Archivkopf dem Archivnamen entspricht -
  der Kopf ist aber der nackte Stempel (`20261116T133541Z/`), der Name traegt das
  Praefix `llm-infra-backup-`. Jedes `--check`, `config` und `database` lief damit in
  ein Verzeichnis, das es nicht gab, und meldete „manifest.json fehlt - Backup
  unvollstaendig“ an einem vollstaendigen Archiv. Jetzt wird nach dem Ordner mit
  `manifest.json` gesucht; ein Ordner als Eingabe gibt sein Pfad zurueck (vorher: leere
  Ausgabe). Messbar: `./scripts/restore.sh --check` sagt **7 Dateien geprueft,
  MANIFEST OK**, `restore.sh config` zeigt den Unterschied zur aktuellen Konfiguration.
- **Die Sicherung enthaelt jetzt die Betreiber-Einstellungen.** `config/host.env` legt
  Pfade, Ports und Containernamen fest und wird von keinem Skript neu erzeugt; es war
  durch die `.env`-Ausnahme komplett draussen. Gesichert wird eine gefilterte Kopie
  (0600), Zeilen mit Schluessel-/Token-/Passwort-/Secret-Namen bleiben weg.
  `restore.sh config` vergleicht sie und nennt den Einsetzbefehl.
- **Selbstpruefung und Aufbewahrung.** `backup.sh` laeuft am Ende `restore.sh --check`
  ueber das gerade geschriebene Archiv (`state/backup-check.log`) und meldet
  „Backup fertig und geprueft“ erst danach; die neuesten drei Archive bleiben
  (`LLM_BACKUP_ANZAHL`), geloescht wird nur nach einem vollstaendigen Lauf.
- **Doku nachgezogen:** `docs/backup-restore.md` (neue Teile, Selbstpruefung,
  Aufbewahrung, Modellteil ohne ZFS), `docs/status.md` begruendet jetzt auch die
  CDI-Warnung als Zurueckhaltung statt Defekt.



## 2026-11-16 (Runde: Ueberwachung lueckenlos - Waechter, Dashboards, Lektuere)

- **Beide Waechter laufen jetzt wirklich.** `llm-litellm-watchdog.timer` prueft alle
  5 Minuten (Lebensanzeige plus 1-Token-Ruf durch den Router),
  `llm-runtime-watchdog.timer` alle 60 Sekunden. Bis dahin war **kein** Waechter
  installiert, obwohl `docs/architecture.md` den Laufzeit-Timer beschrieb.
- **Defekt am Gateway-Waechter (fail-open auf todender Messgroesse).** Die Zahl
  laufender Anfragen wurde auf Port 8001 gegen `sglang:num_running_reqs` gefragt -
  dort antwortet auf diesem Rechner niemand, und das Ergebnis `unknown` galt als
  Freifahrtschein fuer den Neustart, obwohl gerade Anfragen laufen koennen. Gefragt
  wird jetzt der Weiterleiter (`VLLM_METRICS_PORT`, `vllm:num_requests_running`) und
  dann die Runtime; das sglang-Muster bleibt fuer Pennyroyal-Rechner stehen, und ohne
  Zahl wird der Neustart verschoben.
- **Defekt am Laufzeit-Waechter (falsche Unit, falscher Port).** Er pruefte
  `/health` auf Port 8001 (hier: 30000) und wollte `pennyroyal.service` neu starten -
  die es hier nicht gibt. Bei Installation haette er die gesunde Laufzeit dauerhaft
  fuer krank gehalten. Port kommt aus `RUNTIME_PORT`, die Unit aus `RUNTIME_UNIT` oder
  der Suche nach der Unit zu `RUNTIME_CONTAINER`; ohne Treffer bleibt es bei der
  Warnung. Automatischer Neustart bleibt standardmaessig AUS
  (`PENNY_WATCHDOG_RESTART=0`) - ein Runtime-Neustart ist ein eigener, angekuendigter
  Schritt und keine Timer-Automatik.
- **Neuer Arztlauf-Pruefpunkt 17 „Waechter“, gegentested.** Er prueft nicht nur
  `is-active`, sondern ob der Timer eine naechste Laufzeit hat: ein Timer, der einmal
  feuert und nie wieder bewaffnet wird, wirkt aktiv und ueberwacht nichts. Gegentest:
  Timer gestoppt -> WARNUNG mit `./scripts/runtime-watchdog.sh --install`.
- **Speicher-Dashboard ohne totes Ziel.** Das Panel „Modell und PLE auf der Platte“
  frage `llm_ple_backing_bytes` - eine Reihe, die ohne PLE nie existiert; Panel heisst
  „Modell auf der Platte“ und zeigt nur noch die beiden lebenden Reihen. damit
  liefern **alle 101 sichtbaren Messwert-Abfragen der fuenf Dashboards Daten**
  (Panel fuer Panel gegen Prometheus gemessen); die 12 Reihen ohne Daten liegen
  bewusst in der ausgeklappten ZFS/PLE-Zeile, das Logs-Panel ist leer, weil es keine
  Fehler gibt (Strom nachgewiesen).

## 2026-11-16 (Runde: drei Betreiberentscheidungen - Drift, Laufzeit-Unit, Alarmkanal)

- **Lektüre auf den Stand gebracht.** Die README-Tabelle nennt jetzt die benannten
  HTTPS-Einstiege (`https://homepage.localhost`,
  `https://grafana.localhost/grafana/`) vor den Loopback-Adressen, fuehrt Wiki,
  Alertmanager und den vLLM-Weiterleiter, und stattet die Laufzeile mit dem
  tatsaechlichen Port 30000 aus (vorher: Pennyroyal 8001). Das Architekturdiagramm
  zeigt vLLM-Laufzeit, Weiterleiter und die oeffentliche Azure-Route statt des
  sglang-Forks; die alte Messung ist als Stand von 2026-10-02 gekennzeichnet.
  `docs/install.md` beschreibt das Kontoskript statt Handregistrierung, und die
  Skriptkarte in `AGENTS.md` fuehrt `64-setup-open-webui-account.sh`,
  `65-configure-siemens-api.sh`, `70-setup-gateway-proxy.sh`, `71-gateway-keys.sh`,
  `73-setup-vllm-forwarder.sh`, `74-setup-local-proxy.sh`, `76-setup-runtime-unit.sh`
  sowie die neuen Modi von `apply-runtime-unit.sh`.

- **Drift mit dokumentierter Ausnahmeliste.** `scripts/check-drift.sh` fuehrt jetzt
  `ausnahmen=( 'quadlet/pennyroyal.container' )`: die committete Fork-Unit bleibt die
  Wahrheit, der Generator darf sie nicht erreichen. Die Abweichung wird bei jedem Lauf
  mit Kurzstatistik, Begruendung und zwei Aufloesewegen ausgegeben - `make drift` und
  `make ci` sind gruen, ohne dass etwas versteckt ist. Begruendungstext: `docs/status.md`,
  Abschnitt „Pennyroyal-Abweichung“.
- **Laufzeit-Unit aus dem Ist-Zustand, nicht aus Vermutungen.** Neu:
  `scripts/76-setup-runtime-unit.sh` mit zwei Schritten. `--import-from-container
  flash-next-v3` liest den laufenden Container aus und schreibt die versionierte
  Spec `config/runtime/flash-next.spec` (53 Umgebungsvariablen gegen das Bild
  abgeglichen, 65 Schalter, 7 Geraete, 5 Ordner, 3 Obergrenzen, Netzwerk `pasta`,
  `--shm-size 40g`) plus den lauffaehigen Rueckweg
  `state/runtime-restore-flash-next-v3.sh`. Der Generator-Zweig baut daraus
  `quadlet/flash-next.container`; Zugangswert-Namen landen nicht im Repo. Der Generator
  ist in `make drift` aufgenommen.
- **Uebernahme als eigener, pruefender Modus.** `apply-runtime-unit.sh` kennt
  `--install-only` (Units installieren, nichts starten) und `--takeover`: bricht ab bei
  laufenden Anfragen, ohne Rueckwegskript, bei Bild- oder Schalterzahlabweichung
  zwischen Spec und Laeufer, und traegt `RUNTIME_UNIT` in `config/host.env` erst ein,
  wenn die Unit den Container wirklich besitzt.
- **Drei Defekte am Neustart-Schutz behoben:** (1) `running_requests()` fragte nur den
  sglang-Port ab und lieferte bei leerer Antwort `0` - ein Neustart war ins Blaue
  moeglich; jetzt fragen Weiterleiter (vLLM) und Gateway ab, und ohne Zahl wird
  abgebrochen. (2) `RUNTIME_SERVICE` war im Arztlauf benutzt, aber nie gesetzt: die
  Zeile „Unit laeuft“ konnte nie erscheinen, jetzt kommt sie aus `RUNTIME_UNIT` oder
  der Suche nach der Unit zum Container, und sie prueft `is-active` statt nur „nicht
  leer“. (3) `IpcMode=` und `SecurityOpt=` sind in diesem Quadlet unbekannt - die
  Unit wurde vom Generator **komplett uebersprungen**, also unsichtbar; beide Werte
  laufen jetzt ueber `PodmanArgs=`.
- **Alarmkanal entschieden: ohne Empfaenger** (Betreiberentscheidung 2026-11-16).
  Als Soll-Zustand festgehalten in `docs/monitoring.md#alarmkanal`, im Kopf von
  `config/monitoring/alertmanager.yml`, in `docs/status.md` und `docs/HANDOFF.md`.

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
