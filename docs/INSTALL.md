# Installation

1. Repository auf dem Zielhost auschecken und `make preflight` ausführen.
2. `config/host.env.example` und `config/model.env.example` nach den lokalen Anforderungen kopieren. Diese Dateien enthalten keine Secrets.
3. Paket-, ZFS- und NVIDIA-Schritte in dieser Reihenfolge ausführen. Nach dem Treiberskript rebooten.
4. Nach dem Reboot `make podman`, anschließend `make model`, `make pennyroyal`, `make deploy`.
5. Mit `make healthcheck` und `systemctl --user status pennyroyal.service` prüfen.

Für Hugging Face wird ein separat verwaltetes Login/Token benötigt; es darf nicht im Repository landen.

Optionale Erweiterungen werden danach ausschließlich als Framework vorbereitet:

```bash
make gateway
make monitoring
make autossh
make komodo
```

Die Befehle erzeugen bzw. installieren Quadlet-Dateien. Zugangsdaten, SSH-Ziele und Grafana-Secrets müssen vorher lokal in den jeweiligen untracked Konfigurationsdateien eingerichtet werden.
