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
