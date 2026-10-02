# Agentenleitfaden für `llm-infra-setup`

## Zweck

Dieses Repository ist die versionierte Quelle der Wahrheit für eine lokale LLM-Infrastruktur auf CachyOS/Arch Linux mit ZFS, NVIDIA RTX PRO 6000, rootless Podman, Pennyroyal/SGLang und später LiteLLM/Observability.

## Arbeitsmodus

Agenten bauen und ändern primär Dateien im Repository. Sie führen **keine** Installationen, Downloads, Reboots, Containerstarts, systemd-Aktivierungen, ZFS-Mutationen oder Änderungen am Host aus. Erlaubt sind nur lesende Inspektion und statische Prüfungen (z. B. `bash -n`, `make validate`, `git diff --check`). Die erzeugten Skripte werden später vom Betreiber bewusst ausgeführt.

Keine destruktiven ZFS-Befehle (`zpool create/destroy`, `zfs destroy`) hinzufügen. Keine Tokens, Passwörter, SSH-Keys oder Hugging-Face-Secrets committen.

## Ablauf

1. Bestehenden Zustand lesen: `README.md`, `docs/STATUS.md`, `versions.lock`, `Makefile`, relevante Skripte.
2. Neue dauerhafte Konfiguration als idempotentes Skript, Beispielkonfiguration, Quadlet oder Dokumentation hinzufügen.
3. Secrets ausschließlich über externe `.env`-/Secret-Dateien referenzieren; Beispiele enthalten Platzhalter.
4. Statische Prüfungen ausführen: `bash -n scripts/*.sh lib/*.sh`, `make validate`, `git diff --check`.
5. `docs/STATUS.md`, `README.md` und `CHANGELOG.md` aktualisieren: Done und Todo klar trennen.
6. Commit mit präziser Nachricht erstellen.
7. Nach jeder abgeschlossenen Änderung Dokumentation, Commit und Push ausführen; vor dem Push nur die zugehörigen Dateien stagen und fremde uncommittete Änderungen unangetastet lassen.

## Skript-Map

| Datei | Aufgabe |
|---|---|
| `scripts/00-preflight.sh` | Read-only Hostaufnahme in `state/preflight-report.txt` |
| `scripts/10-install-packages.sh` | Fehlende Arch-Pakete deklarativ installieren (Betreiber führt aus) |
| `scripts/20-zfs-setup.sh` | Vorhandenes ZFS prüfen und Dataset für Modelle anlegen |
| `scripts/30-nvidia-podman.sh` | Rootless Podman, Linger, NVIDIA CDI und GPU-Test vorbereiten |
| `scripts/35-install-nvidia-driver.sh` | NVIDIA Open DKMS, Module und Initramfs vorbereiten |
| `scripts/40-download-model.sh` | Gepinntes Hugging-Face-Modell in ZFS laden |
| `scripts/50-install-pennyroyal.sh` | Gepinntes Image ziehen und Quadlet-Unit erzeugen |
| `scripts/deploy.sh` | Quadlet in User-Konfiguration installieren und aktivieren |
| `scripts/healthcheck.sh` | Lokalen Runtime-Health-Endpunkt prüfen |
| `scripts/benchmark.sh` | Erreichbarkeit als Benchmark-Voraussetzung prüfen |
| `scripts/backup-config.sh` | Nicht geheime Repo-Konfiguration archivieren |
| `scripts/validate.sh` | Shell/JSON/Diff-Qualitätsprüfungen |

## Konfiguration und Reihenfolge

- `config/host.env.example`: Pfade und Ports; lokale Kopie bleibt untracked.
- `config/model.env.example`: Modell-ID, Image-Tag, Profil und Kontext.
- `versions.lock`: beobachtete Hostversionen und gepinnte Referenzen, niemals Geheimnisse.
- Empfohlene Betreiberreihenfolge: `preflight` → Pakete → ZFS → NVIDIA/Reboot → Podman/CDI → Modell → Pennyroyal-Unit → Deploy → Healthcheck.
- Netzwerkdienste sollen später über LiteLLM (`:4000`) gehen; SGLang (`:8001`) nicht öffentlich exponieren.

## Erweiterungen

Neue Dienste gehören als versionierte Quadlet-/systemd-Datei plus Beispielkonfiguration und Dokumentation ins Repo. Für jedes Feature müssen Voraussetzungen, Ausführung, Rollback/Fehlerdiagnose und Status dokumentiert werden. Upstream-Versionen vor Aktualisierung prüfen und in `versions.lock` begründen.
