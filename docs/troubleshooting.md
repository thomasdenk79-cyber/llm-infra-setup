# Fehlerbilder

Jeder Abschnitt: woran man es erkennt, warum es passiert, was zu tun ist.

## Nach einem Neustart startet die Runtime nicht

*Erkenntnis:* `systemctl --user status pennyroyal.service` zeigt einen Fehler,
im Journal steht etwas wie `no such file or directory` oder der Container startet
nicht, obwohl das Modell da ist.

*Ursache:* Der SSD-Speicher fuer die Einbettungstabellen (`/srv/llm/ple-ext4`)
war nur von Hand eingehaengt und fehlt damit nach einem Neustart. Die Unit-Datei
verlangt diesen Pfad (`RequiresMountsFor`).

*Loesung:*

```bash
./scripts/47-setup-ple-storage.sh
./scripts/doctor.sh
```

Das Skript ergaenzt den Eintrag in `/etc/fstab` (mit `nofail`, damit der Rechner
auch ohne die Platte hochfaehrt). Der Doctor prueft den fstab-Zustand dauerhaft
uber die Kennzahl `llm_ple_in_fstab`.

## Runtime kommt nicht hoch

```bash
journalctl --user -u pennyroyal.service -n 200 --no-pager | tail -60
```

| Meldung im Journal | Grund | Massnahme |
|---|---|---|
| `OSError: Function not implemented (os error 38)` | io_uring wird vom Seccomp-Profil oder von ZFS blockiert | `make pennyroyal` erzeugt die Unit mit `seccomp=unconfined` und ext4-Loop fuer PLE; PLE liegt nicht auf ZFS |
| `CUDA out of memory` | zu viel reserviert oder ein anderes Programm belegt die Karte | `nvidia-smi`, Runtime neu starten; `PENNY_HICACHE_SIZE_GB` pruefen |
| `Required executable missing` | Bild oder Startskript passt nicht zusammen | `make pennyroyal`, dann `./scripts/apply-runtime-unit.sh` |
| `Target checkpoint incomplete` | Modell unvollstaendig | `make model` (setzt fort), danach `make model-verify` |
| `tokenizer differs from the qualified FR-Spec tokenizer` | anderes Modell als fuer dieses Startskript freigegeben | `config/model.env` pruefen, nicht mit Gewalt starten |
| Kein `nvidia.com/gpu` in `nvidia-ctk cdi list` | CDI veraltet (neuer Treiber, Karte umgesteckt) | `make podman` |
| Container startet, API aber nie gesund | Kaltstart laeuft noch (15 Minuten) | `journalctl ... -f` zuwarten lassen |

## Chat antwortet nicht, aber die API schon

*Ursache:* Open WebUI ist nicht mit dem Gateway verbunden, oder der erste Account
fehlt (die Registrierung war schon aus).

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:4000/health
podman logs open-webui 2>&1 | tail -20
```

Der Schluessel in `~/.config/llm-infra/open-webui.env` muss mit
`LITELLM_MASTER_KEY` aus `gateway.env` uebereinstimmen; nach einem
`rotate-secrets.sh` beide Dateien neu schreiben.

## Grafana will das Passwort nicht

```bash
podman secret inspect grafana_admin_password >/dev/null || ./scripts/ensure-credentials.sh
./scripts/reset-grafana-password.sh
systemctl --user restart grafana.service
```

## Prometheus zeigt `pennyroyal` als down

Die Runtime antwortet, aber die Unit-Datei des Prometheus war noch die aeltere
Version ohne Inferenz-Netz.

```bash
./scripts/apply-runtime-unit.sh --dry-run     # zeigt den Unterschied
./scripts/apply-runtime-unit.sh               # installiert die neue Datei
curl -s 'http://127.0.0.1:9090/api/v1/query?query=up' | python3 -m json.tool | grep -A2 job
```

## Host-Kennzahlen fehlen in Grafana

```bash
./scripts/collect-host-facts.sh            # schreibt die Datei neu
curl -s http://127.0.0.1:9100/metrics | grep node_textfile_scrape_error
```

Der Wert muss `0` sein. `1` bedeutet, dass eine Familie in der Textdatei keine
`# TYPE`-Zeile hat (oder dass die Datei beim Schreiben beschadigt war). Die
assemble-Funktion in `scripts/collect-host-facts.sh` fuegt sie automatisch ein.

## SMART zeigt keine Werte

`sudo -n smartctl ...` braucht sudo ohne Passwortabfrage. Ohne diesen Zugang
bleibt `llm_smart_available 0`; der Doctor meldet es.

## Etwas wurde versehentlich von Hand geaendert

Repo und Laeufer laufen auseinander:

```bash
./scripts/apply-runtime-unit.sh --list     # was ist anders?
make drift                               # committete Units gegen Generatoren
```

## Zwei Units streiten um denselben Containernamen

Passiert nach Umbenennungen (alte Unit-Datei noch im User-Ordner). Die Deploy-
Skripte entfernen bekannte Altlasten selbststaendig (`prune_legacy_units` in
`lib/units.sh`). Manuell:

```bash
ls ~/.config/containers/systemd
systemctl --user cat <name>.service | grep Image=
```
