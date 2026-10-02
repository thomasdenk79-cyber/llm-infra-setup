# Projektstatus

Stand: 2026-10-02

## Done

Die in `scripts/00-preflight.sh`, `10-install-packages.sh`, `20-zfs-setup.sh`, `30-nvidia-podman.sh` und `35-install-nvidia-driver.sh` beschriebenen Host-Schritte sind implementiert. Die Runtime-Kette ist bis zum rootless Quadlet vorbereitet: Modell-Download (`40`), Image/Unit (`50`) und Deployment sind vorhanden.

## Todo

1. Upstream-Pennyroyal-Release prüfen und `versions.lock` nur mit belegter kompatibler Version ändern.
2. Modell und Runtime auf dem Host ausführen; Logs, `/health` und GPU-Auslastung dokumentieren.
3. Gateway und Observability-Dienste als Quadlets ergänzen.
4. Operations-, Backup- und Security-Dokumentation nach realem Betrieb vervollständigen.

## Betriebsregeln

- Vor jeder Änderung `make preflight` ausführen.
- ZFS-Pools niemals automatisch erstellen, zerstören oder umstrukturieren.
- Alle dauerhaften Hoständerungen müssen über dieses Repository reproduzierbar sein.

### L15-eGPU-Sonderfall

Die KWin-Wayland-GPU-Auswahl für den ThinkPad L15 Gen 2 (20X4) mit Blackwell-eGPU ist in `config/kde/90-kwin-egpu.conf` versioniert und wird mit `make kwin-egpu` installiert.

## Monitoring / Observability

### Done

- Versionierte Quadlet-Vorlagen für Prometheus, Grafana, Loki, Grafana Alloy und Dozzle.
- Eigenes rootless Podman-Netz `llm-observability.network`.
- Prometheus scrape-Konfiguration für Prometheus und die Pennyroyal-Metriken.
- Grafana-Provisioning für Prometheus und Loki als Datenquellen.
- Loki-Dateispeicher und Prometheus/Grafana/Loki-Datenverzeichnisse unter `$HOME/.local/share/llm-infra`.
- `make monitoring` installiert die Units in das rootless systemd-Verzeichnis; es werden keine Container automatisch gestartet.

### Todo / Betriebshinweise

- Vor dem Start ein rootless Podman Secret `grafana_admin_password` anlegen; kein Passwort wird im Repository gespeichert.
- Podman-Socket-Zugriff für Alloy/Dozzle auf dem Zielhost prüfen und bei Bedarf über `systemctl --user enable --now podman.socket` aktivieren.
- Nach dem ersten Start Datenquellen, Dashboards, Retention und externe Erreichbarkeit härten.
- Image-Tags regelmäßig gegen Upstream prüfen und danach in den Quadlets pinnen/aktualisieren.

LiteLLM, Autossh und Komodo-Periphery-Units sind generatorisch vorbereitet; Aktivierung und Zugangsdaten bleiben hostabhängig.

## Version review

Am 2026-10-02 wurden die externen Images geprüft und die beweglichen `latest`/`main-stable` Referenzen entfernt: LiteLLM `v1.101.0`, Komodo Periphery `2.3.3`. Pennyroyal bleibt auf dem dokumentierten RTX-PRO-6000-Referenzstand `v2.5.3`, bis die SM120-Kompatibilität eines neueren Releases separat geprüft ist.
