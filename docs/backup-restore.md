# Sichern und Wiederherstellen

## Was gesichert wird

`./scripts/backup.sh` legt in `state/backups/<zeitstempel>.tar.gz` ab:

| Teil | Inhalt | Wie |
|---|---|---|
| Konfiguration | `config/`, `quadlet/`, `systemd/`, `containers/`, `docs/`, `Makefile`, `versions.lock` | Tar-Archiv ohne lokale `.env`-Dateien |
| Datenbank | LiteLLM-Nutzung und virtuelle Schluessel | `pg_dump` im laufenden Container |
| Zustand | Chat-Daten, Grafana-Einstellungen, Portal-Konfiguration | Tar pro Ordner |
| Betreiber-Einstellungen | `config/host.env` ohne Zugangswerte | gefilterte Kopie (0600); kein Skript erzeugt die Datei neu |
| Modell | **kein** Datenklau, nur ein ZFS-Snapshot-Hinweis | `zfs snapshot` auf dem Modell-Dataset |
| Maske | SHA256-Pruefsummen aller Dateien | `manifest.json` |

Das Modell selbst (rund 50 GiB) wird nicht kopiert. Dafuer gibt es einen
ZFS-Snapshot, und falls der Rechner ganz verloren geht, wird das Modell mit
`make model` erneut geladen ( revisionsgesichert in `versions.lock`). Auf
Rechnern ohne ZFS - dieser Rechner ist einer - bleibt der Modellteil ein
leerer Hinweis: gesichert werden Konfiguration, Datenbank, Zustand und
Betreiber-Einstellungen.

Warum so aufgeteilt: eine 110-GiB-Sicherungsdatei auf demselben Rechner ist
keine Sicherung, und ein Vollkopie-Lauf wuerde den Datenschutz des Modells
verdoppeln, ohne etwas zu gewinnen.

## Backup anlegen und pruefen

```bash
./scripts/backup.sh                     # in state/backups/
./scripts/backup.sh /media/usb/llm      # auf einen USB-Stick
./scripts/restore.sh --list             # vorhandene Rueckhalte
```

`make backup` ruft dasselbe Skript auf.

Am Ende jedes Laufs prueft das Skript sein eigenes Archiv (`restore.sh --check`,
Protokoll in `state/backup-check.log`): erst wenn Manifest und Pruefsummen stimmen,
geht die Meldung `Backup fertig und geprueft` raus. Ein Lauf mit fehlenden Teilen
endet bei 1 und nennt den naechsten Befehl - die Archive behalten also nichts
Lueckenhaftes als Erfolg.

Aufbewahrung: behalten werden die neuesten drei Archive
(`LLM_BACKUP_ANZAHL=5 ./scripts/backup.sh` fuer mehr). Geloescht wird nur nach
einem vollstaendigen Lauf, damit ein fehlerhafter Lauf nicht die letzte gute
Sicherung wegrotiert.

**Wichtig:** Der Backup-Ordner liegt im Repository, aber `state/` ist in Git
ausgeschlossen. Fuer eine echte Sicherung muss das Archiv auf ein zweites
Medium (USB, NAS). Ein Rebuild aus Git ersetzt keine Datenbank.

## Wiederherstellen

Reihenfolge nach Totalausfall:

```bash
git clone <dein Repository-URL> llm-infra-setup && cd llm-infra-setup
./scripts/ensure-credentials.sh            # neue lokale Zugangsdaten
tar -xzf /media/usb/llm/llm-infra-backup-<stempel>.tar.gz -C /media/usb/llm
./scripts/restore.sh --check /media/usb/llm/<stempel>       # Pruefsummen
./scripts/restore.sh config  /media/usb/llm/<stempel>       # Konfiguration zurueck
./scripts/restore.sh database /media/usb/llm/<stempel>      # Datenbank einspielen
make deploy-ready
./scripts/doctor.sh
```

`restore.sh config` loescht nichts. Es packt die Sicherung in einen
Legestatt-Ordner, zeigt den Unterschied zur aktuellen Konfiguration und nennt
den Befehl, mit dem du sie selbst uebernimmst.

`restore.sh database` fragt nach (J/N), weil es den bestehenden Inhalt der
LiteLLM-Datenbank ersetzt.

## Regelmaessigkeit

Ein Backup vor jeder groesseren Aenderung (Modell-Upload, Treiber, Pennyroyal-
Version) und sonst woechentlich. Der Doctor meldet sich, wenn die letzte
Sicherung aelter als 7 Tage ist.

## Was bewusst nicht automatisch geloescht wird

ZFS-Snapshots bleiben erhalten, damit ein Versehen nicht zwei Ebenen
Konfiguration gleichzeitig zerstoert. Aufraeumen von Hand:

```bash
zfs list -t snapshot -o name,creation,used | grep llm-infra
zfs destroy <name>          # erst ansehen, dann loeschen
```

## Test der Wiederherstellung

Mindestens einmal testen, ob die Kette wirklich funktioniert:

```bash
./scripts/backup.sh /tmp/llm-test
tar -xzf /tmp/llm-test/llm-infra-backup-*.tar.gz -C /tmp/llm-test
./scripts/restore.sh --check /tmp/llm-test/<stempel>
```

Erwartetes Ergebnis: `MANIFEST OK` und "N Dateien geprueft".
