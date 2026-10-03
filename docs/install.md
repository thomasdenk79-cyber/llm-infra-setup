# Ersteinrichtung auf einem Rechner

Voraussetzung: CachyOS/Arch mit ZFS-Wurzel, eine NVIDIA-Karte mit mindestens
24 GiB VRAM, ein ZFS-Pool, der unter `/srv` eingehaengt ist, und ein Benutzer
ohne verschluesseltes Home-Verzeichnis.

## Kurzweg (empfohlen)

```bash
git clone <deine Repository-URL> ~/work/llm-infra-setup
cd ~/work/llm-infra-setup
cp config/host.env.example config/host.env
nano config/host.env        # nur noetig, wenn Pfade/Ports anders sind
./setup.sh
```

`./setup.sh` ist der eine Befehl fuer alles. Er ist wiederholbar: Wenn er
abbricht (Netzwerk, Neustart, abgesteckte GPU), starte denselben Befehl erneut -
fertige Schritte werden uebersprungen. Er endet mit einer Diagnose und nennt die
noch offenen Punkte.

## Was in welcher Reihenfolge passiert

| Phase | Was passiert | Befehl dahinter | Dauer |
|---|---|---|---|
| 1 | ZFS-Dataset pruefen/anlegen, ARC-Deckel setzen | `make zfs` | Sekunden |
| 2 | fehlende Pakete installieren | `make install` | Minuten |
| 3 | Treiber pruefen, ggf. DKMS bauen | `make nvidia-driver` | Minuten, dann Neustart |
| 4 | Podman-Socket, Linger, CDI, GPU-Test | `make podman` | Sekunden |
| 5 | Modell herunterladen und pruefen | `make model` | je nach Netz lange (fortsetzbar) |
| 6 | Bild ziehen, Runtime-Unit erzeugen | `make pennyroyal` | Minuten |
| 7 | PLE-Speicher vorbereiten | `make ple-nvme` | Minuten, prueft /etc/fstab |
| 8 | Portal, Chat, Gateway, Beobachtung | `make deploy-non-gpu` | Minuten |
| 9 | Runtime starten, auf API warten, Rauchtest | `make deploy-ready` | ca. 15 Minuten |
| 10 | OpenCode-Anbindung (nur wenn nichts existiert) | in `setup.sh` | Sekunden |

## Einzelschritte (wenn du lieber selbst steuerst)

```bash
make preflight          # Host-Zustand in state/preflight-report.txt
make validate           # Repo-Pruefung
make install
make zfs
make nvidia-driver      # danach: sudo systemctl reboot, dann weiter
make podman
make model              # model-verify prueft danach automatisch
make pennyroyal
make ple-nvme
make deploy-non-gpu     # Portal + Chat + Gateway + Beobachtung, ohne GPU
make deploy-ready       # komplett, inklusive Runtime
make healthcheck
./scripts/doctor.sh
```

## Nach dem ersten Start

```bash
./scripts/show-credentials.sh    # Zugangsdaten anzeigen
./scripts/backup.sh              # erste Sicherung anlegen
```

Browser: http://127.0.0.1:3002 (Portal), http://127.0.0.1:3001 (Chat).
Im Chat einmal registrieren - dieser Account ist Admin - danach
`ENABLE_SIGNUP=false` in `~/.config/llm-infra/open-webui.env` setzen.

## ThinkPad L15 mit externer Grafikkarte

Der externe Haengemonitor haengt an der externen Karte, das interne Panel an der
Intel-Grafik. `make kwin-egpu` stellt die Reihenfolge der Grafikgeraete ein;
danach ab- und wieder anmelden. Das Skript prueft den Rechnername-Typ und bricht
auf anderen Geraeten ab.

## Was gebraucht wird, aber nicht automatisch passiert

* Hugging-Face-Zugang, falls das Modell ihn verlangt: Token **ausserhalb** von
  Git setzen (`hf auth login` oder Umgebungsvariable).
* sudo ohne Passwortabfrage, falls du `./setup.sh` unbeaufsichtigt laufen lassen
  willst.
* zweite Festplatte/NVMe-Partition fuer die schnellere PLE-Ablage
  (`PLE_BLOCK_DEVICE`, siehe `docs/performance.md`).
