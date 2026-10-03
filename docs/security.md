# Sicherheit

Annahme: ein Arbeitsplatzrechner in einem privaten Netz. Das Modell soll lokal
bleiben, und niemand aus dem Netz soll schreiben oder ablesen koennen, was nicht
fuer das Netz bestimmt ist.

## Was bereits umgesetzt ist

* **Kein Port im Netz.** Alle Dienste binden an `127.0.0.1` (siehe
  `quadlet/*.container`). Kein Client kann im LAN anfragen.
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
nur zu einem von dir eingetragenen Rechner.

## Was noch fehlt (offene Aufgaben)

* eigenes seccomp-Profil statt `unconfined`
* HTTPS fuer Portal/Grafana, falls je ein echtes Netz bedient werden soll
* Pruefung, dass `PENNYROYAL_PROTECT` vor Aenderungen an der GPU gesetzt ist
* regelmaessiger Test, ob die Wiederherstellung wirklich klappt
  (siehe letzter Abschnitt in `docs/backup-restore.md`)
