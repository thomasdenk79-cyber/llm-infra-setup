# Sicherheit

Annahme: ein Arbeitsplatzrechner in einem privaten Netz. Das Modell soll lokal
bleiben, und niemand aus dem Netz soll schreiben oder ablesen koennen, was nicht
fuer das Netz bestimmt ist.

## Was bereits umgesetzt ist

* **Gezielte LAN-Freigabe.** Die Backend-Dienste bleiben auf Loopback. Caddy
  443 und der vLLM-Weiterleiter 30001 sind die dokumentierten Ausnahmen;
  beide sind auf das vertrauenswuerdige Kabel-LAN begrenzt.
* **Kein Root.** Alles laeuft rootless als Benutzer; nur Paket-, Treiber- und
  ZFS-Schritte brauchen `sudo`.
* **Zwei Netze.** Inferenz und Beobachtung sind getrennt; Prometheus ist der
  einzige Uebergang (Begruendung in `docs/adr/0009-*.md`).
* **Zufalls-Passwoerter.** Zugangswerte werden bei der ersten Einrichtung
  erzeugt und liegen ausserhalb des Repos in `~/.config/llm-infra/` (0600) bzw.
  als Podman-Secret. Die alten hart eingetragenen Standardwerte sind aus dem
  Code entfernt; `make validate` prueft darauf.
* **Schluessel nicht im Log.** Der Git-Guard in `scripts/validate.sh` meldet HF-
  und OpenAI-artige Schluessel sowie private SSH-Schluessel; zusaetzlich laeuft
  `detect-secrets` als Pre-Commit-Hook.
* **Modell und Gewichte sind read-only** eingehaengt (`:ro`), damit ein Fehler
  im Inferenz-Container die Dateien nicht veraendern kann.
* **Waechter startet nicht grundlos neu.** Der Runtime-Waechter warnt
  standardmaessig und loest einen Neustart nur nach drei Fehlversuchen *und* nur
  bei leerer Warteschlange aus.
* **Rueckgabepfad** fuer Konfiguration und Datenbank siehe `docs/backup-restore.md`.

## Bekannte Kompromisse

**1. `seccomp=unconfined` fuer den Inferenz-Container.** Der SSD-Vorleser der
Runtime braucht `io_uring`; das Standardprofil von Podman blockiert den
Aufbauaufruf auf diesem Host. Das ist ein bewusster, dokumentierter Ausnahmetag
(`PENNY_SECURITY_OPT`) und betrifft nur den einen Container. Sauberer waere ein
eigenes Profil, das genau diese Aufrufe erlaubt - nach oben auf der Liste der
offenen Aufgaben.

**2. Die Runtime hoert im Container auf `0.0.0.0`.** Das ist fuer Podman
ungefaehrlich, weil nur `127.0.0.1:8001` veraeffentlicht wird. Wer das streng
nehmen will: `--host` im Rezept auf `127.0.0.1` setzen - dann muss aber auch
`HealthCmd` angepasst werden.

**3. Open WebUI Registrierung steht beim ersten Start auf `true`.** Der erste
Account wird Admin. Danach in `~/.config/llm-infra/open-webui.env` auf `false`
setzen und `systemctl --user restart open-webui.service` ausfuehren. Der Grund
fuer die Einschaltung steht als Kommentar in der Datei.

**4. Alloy und Dozzle duerfen den Podman-Socket lesen.** Damit koennen sie
Container steuern. Wer das nicht will: Dozzle braucht den Socket nur fuer die
Oberflaeche und kann entfernt werden (`make apply-units` zeigt, was sich aendert).

**5. Keine Verschluesselung im Betrieb.** Zugriffe erfolgen ueber SSH-Port-
weiterleitung (siehe `docs/operations.md`), nicht ueber HTTP im Netz. Der
optionale Wartungstunnel (`make autossh`) uebertraegt nur den Gateway-Port und
nur zu einem von dir eingetragenen Rechner. Seit 2026-11-17 gilt das nicht mehr
uneingeschraenkt: Der LAN-Zugang bedient HTTPS (TLS) - dieser Punkt beschreibt
die *uebrigen* Dienste, die weiterhin ohne TLS auskommen.

## LAN-Zugang ueber HTTPS - Netz, Git und Protokolle (gemessen 2026-11-17)

Was tatsächlich im Netz hoert (`ss -tlnH`, Gegenprobe `--check`):

| Etwas | Wo | Schutz |
|---|---|---|
| `127.0.0.1:443` und `LAN_BIND_IPS:443` (Caddy `llm-proxy`) | LAN und Loopback | TLS; pro Route wie folgt |
| Portal, Grafana, Anleitung | ueber 443 | Portal prueft Host-Header (`HOMEPAGE_ALLOWED_HOSTS`); Grafana anonym **lesend** (`GF_AUTH_ANONYMOUS_ORG_ROLE=Viewer`, gemessen) |
| Gateway-Routen `littlem`, `llm-direct` | ueber 443 | LiteLLM-Schluessel, 401 ohne |
| `dozzle` | ueber 443 | Basic-Auth im Proxy (bcrypt, siehe unten) |
| `direct-llm` | ueber 443 | ohne API-Schluessel/Proxy-Login, nur an `LAN_BIND_IPS` |
| unbekannter Hostname | Fallback-Site | gemessen: TLS-Abbruch ohne passendes Zertifikat, sonst `403 "Unbekannter Name"`; reicht an kein Backend weiter |
| `30001` (vLLM-Weiterleiter) | **Adresse der bevorzugten Standard-Route, also Kabel-LAN** (WLAN seit 2026-11-17 zu) | keine Anmeldung; bewusste Grenze ist das private LAN |

Die 15 in `--check` geprueften Ports (3000, 3001, 3002, 3100, 4000, 5432, 8080,
9090, 9093, 9835, 30000, 3003, 9100, 12345, 8120) sind loopback-only oder
werden nur in Containernetzen gebunden. Ausgenommen ist 30001, der bewusst auf
der bevorzugten LAN-Adresse lauscht; 8001 gehoert zur nicht laufenden
Referenz-Unit.

**Basic-Auth-Qualitaet (gemessen).** Caddy v2.11.9; der Dozzle-Hash `$2a$14$...`
(bcrypt, Kostenfaktor 14 - Caddy-Standard, gegen die Hashwerte selbst geprueft,
nicht gegen das Bild). Realm `restricted`. Falscher Benutzer und falsches
Passwort liefern dieselbe 401-Antwort - keine Aufzaehlung. Kein Sperrverhalten
nach Fehlversuchen: Der Schutz steht und faellt mit der Passwortlaenge
(24 Zeichen aus `/dev/urandom`, erzeugt in `new_password()`).

**Klartext fluechtig im Prozessverzeichnis.** Beim Erzeugen der Hashes uebergibt
`caddy_hash()` das Passwort als Argument (`podman run ... hash-password
--plaintext <wert>`); es steht damit kurz im `/proc/<pid>/cmdline` eines jeden
lokalen Prozesses (gemessen mit einem Dummywert). Ebenso zeigt `--check` die
Zugangsdaten als `curl -u`-Argument. Bewertung: gering - nur waehrend der
Erzeugung bzw. des Prueflaufs, nur fuer lokale Prozesse, ein Benutzer auf dieser
Maschine. Behoben werden kann es durch Uebergabe per stdin
(`printf '%s' "$pw" | podman run -i ... caddy hash-password`, funktioniert,
gemessen) bzw. `curl --config -`.

**Kopfzeilen stromaufwaerts.** Caddy entfernt den `Authorization`-Kopf nach
erfolgreicher Dozzle-Basic-Auth nicht; Dozzle nimmt heute keine Credentials ab.
`direct-llm` hat absichtlich keine vorgeschaltete Anmeldung. Sobald Dozzle
stromaufwaerts eine eigene Anmeldung eingefuehrt wird, kann der weitergereichte
Kopf dort Konflikte oder Protokolleintraege erzeugen - vorgesehenes Gegenmittel:
`header_up -Authorization` in der Dozzle-Route. `X-Forwarded-*` setzt Caddy;
kein Backend entscheidet damit ueber Zugang.

**Host-Header und Fallback (Gegenproben gemessen).** `Host: evil` an der
LAN-Adresse liefert 403 (Fallback), `Host: dozzle.*` an der IP scheitert am
TLS (kein Zertifikat fuer unbekannte Namen), SNI/Host-Mismatch wird nach dem
Host-Header geroutet - die Dozzle-Basic-Auth greift, wenn deren Hostname
getroffen wird. Ein Weg durch die Fallback-Site an ein Backend existiert nicht.
Beachte: die `.localhost`-Namen beantwortet der
Proxy auch an der LAN-Adresse (Caddy bindet nach Port, nicht nach Interface);
die Inhalte sind deckungsgleich mit den LAN-Namen; eine Zusatzexposition ist
damit nicht verbunden.

**Was in Git landet:** nichts an Zugangswerten. Die History (179 Commits) wurde
mustersuchend geprueft (OpenAI-/HF-Schluessel, private Schluessel, bcrypt-Hashes,
Passwortfelder): keine echten Geheimnisse; die `sk-loc…`-Platzhalter in
`config/litellm.yaml` sind Lokal-Attrappen ohne Wert. **Achtung Betriebsregel:**
Arbeitsverzeichnisse unter `.omo-work/` (Testkopien des Baums, inklusive
`home/.config/llm-infra/proxy/`) liegen unversioniert im Repo und sind nicht
in der `.gitignore` - vor jedem `git add -A` loeschen oder `.gitignore`
erweitern (Vorschlag in `.omo-work/review-codex.md`).

**Was in Protokolle landet:** Caddy zeichnet Standardzugriffe im Container-Log
auf (URL-Pfad, Status, Client-IP); Zugangswerte erscheinen darin nicht, auch
nicht bei 401. Dozzle-Logs koennen Zugangswerte *anderer* Container enthalten -
deshalb steht die Log-Route hinter Basic-Auth.

**TLS der internen CA (gemessen).** Root `Caddy Local Authority - 2026 ECC Root`
gilt 10 Jahre; die Zwischenstufe laeuft nach 7 Tagen aus und wird
automatisch erneuert; Ausstellungsblaetter gelten 12 Stunden. Ein Client, der
nur dem Root vertraut, merkt die Rotation nicht. Wechselt der Rechnername,
aendert sich `LAN_DOMAIN`, das Ausstellungsblatt wird automatisch neu ausgestellt
- die hosts-Eintraege auf Windows muessen nachgezogen werden
(`--print-hosts`, dann das PowerShell-Skript erneut laufen lassen). Beim
Import auf Windows laesst sich der SHA-256-Fingerprint erzwingen:
`-ExpectedThumbprint '<wert von openssl x509 -noout -fingerprint -sha256>'`.

## Bewusste LAN-Grenze und weitere Verbesserungen

* eigenes seccomp-Profil statt `unconfined`
* ~~HTTPS fuer Portal/Grafana, falls je ein echtes Netz bedient werden soll~~
  - erledigt 2026-11-17 (LAN-Zugang, Abschnitt oben); uebrig gebliebene Luecken:
* **`direct-llm` und Port 30001 sind ohne Anmeldung im privaten Kabel-LAN**
  erreichbar. Das ist die gewaehlte Vertrauensgrenze, keine per-Benutzer-
  Authentifizierung; die WLAN-Adresse ist nicht gebunden. Falls das Netz spaeter
  erweitert wird, muss die Freigabe neu bewertet werden. Eine Verengung auf
  Loopback plus Podman-Gateway ist **nicht** ausfuehrbar (gemessen:
  `up{job="vllm"}` auf 0, `direct-llm` auf 502, weil Gateways im Host-Namespace
  nicht bindbar sind); Begruendung und Messung in `docs/runtime.md`.
* ~~Loopback-Pruefliste der 74er-Generators um 3003, 9100, 12345 (und 8001, 8120)
  erweitern~~ - erledigt 2026-11-17 (3003, 9100, 12345, 8120 in
  `LOOPBACK_ONLY_PORTS`; 8001 bleibt aus, weil die Pennyroyal-Runtime bewusst
  ad hoc laeuft).
* `Authorization`-Kopf in der Dozzle-Basic-Auth-Route stromaufwaerts entfernen
  (`header_up -Authorization`), bevor dort eine eigene Anmeldung einzieht.
  Bewusst noch nicht getan: die Gateway-Routen brauchen den Kopf fuer die
  API-Schluessel, ein pauschales Entfernen wuerde LiteLLM brechen.
* ~~Gegenprobe "falsches Passwort liefert 401" in `--check` ergaenzen~~ -
  erledigt 2026-11-17 (die Dozzle-Basic-Auth-Route prueft Zugang, fehlenden
  Zugang und ein bewusst falsches Passwort).
* Pruefung, dass `PENNYROYAL_PROTECT` vor Aenderungen an der GPU gesetzt ist
* regelmaessiger Test, ob die Wiederherstellung wirklich klappt
  (siehe letzter Abschnitt in `docs/backup-restore.md`)
