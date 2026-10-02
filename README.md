# llm-infra-setup

Reproduzierbare lokale LLM-Infrastruktur für CachyOS/Arch Linux mit NVIDIA RTX PRO 6000, ZFS, Podman und Pennyroyal/SGLang.

## Aktueller Stand (2026-10-02)

### Erledigt und im Repository versioniert

- Host-Preflight mit Bericht unter `state/preflight-report.txt` (OS, Kernel, GPU, CUDA, PCIe, ZFS, Container- und Netzwerkstatus).
- Paket- und NVIDIA-Open-DKMS-Setup einschließlich Module, Nouveau-Blacklist und CDI-Erzeugung.
- Idempotentes ZFS-Dataset-Setup für `/srv/llm/models`, Cache- und NIXL-Verzeichnisse.
- Rootless-Podman-Vorbereitung und GPU-Smoke-Test.
- Gepinnte Runtime-Referenz: `ghcr.io/jpezzulli/sglang-rtxpro6000:v2.5.3`; Modell: `RadixArk/Qwen3.8-Flash-Next-NVFP4`.
- Reproduzierbare Skripte für Modell-Download, Quadlet-Erzeugung, Deployment, Healthcheck und Konfigurationsbackup.
- `versions.lock` dokumentiert den zuletzt erfassten Hoststand und enthält keine Zugangsdaten.

### Noch offen

- Pennyroyal-Release und Modellkompatibilität gegen die aktuelle Upstream-Quelle prüfen, bevor ein Upgrade von v2.5.3 erfolgt.
- Hugging-Face-Zugang (falls erforderlich) außerhalb von Git konfigurieren und Modell mit `make model` laden.
- Runtime nach Reboot auf dem Zielhost starten und mit `make healthcheck` prüfen.
- LiteLLM-Gateway, Prometheus/Grafana, Loki/Alloy, Dozzle, Komodo, Autossh und `llmctl` als weitere versionierte Dienste ergänzen.
- Backup/Restore, Lasttest und Sicherheits-Härtung nach erfolgreichem Einzel-GPU-Betrieb dokumentieren.

## Schnellstart

```bash
cp config/host.env.example config/host.env
cp config/model.env.example config/model.env
make preflight
make validate
make install          # falls Pakete fehlen
make zfs              # bestehende Pools werden nicht zerstört
make nvidia-driver    # reboot danach erforderlich
make podman
make pennyroyal       # Image pullen und Quadlet erzeugen
make deploy
make healthcheck
```

`state/`, lokale `.env`-Dateien und Geheimnisse sind von Git ausgeschlossen. Niemals Tokens in `versions.lock` oder Konfigurationsdateien committen.

### ThinkPad L15 Gen 2 mit Blackwell-eGPU

Auf dem L15 Gen 2 (20X4) hängt der externe Monitor an der Blackwell über Thunderbolt, während das interne Panel an der Intel-iGPU hängt. `make kwin-egpu` setzt `KWIN_DRM_DEVICES=/dev/dri/card0:/dev/dri/card1`, damit KWin die Blackwell als primäre DRM-GPU nutzt und den ineffizienten Multi-GPU-Compositingpfad vermeidet. Nach der Installation ist eine neue Plasma-Sitzung erforderlich.
