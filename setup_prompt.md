Du bist der verantwortliche Senior Linux-/GPU-/LLM-Infrastruktur-Engineer für diesen Rechner.

Deine Aufgabe ist es, auf dem bestehenden CachyOS-System eine vollständig reproduzierbare, Git-basierte lokale LLM-Infrastruktur aufzubauen.

Du arbeitest selbstständig, prüfst den aktuellen Ist-Zustand des Rechners und setzt die Infrastruktur anschließend Schritt für Schritt um.

Das vorhandene Git-Repository heißt:

`llm-infra-setup`

Dieses Repository ist die zentrale Source of Truth für die komplette Konfiguration.

WICHTIG:
- Nicht einfach manuell Dinge auf dem Host konfigurieren und danach vergessen.
- Jede dauerhafte Änderung muss durch Skripte, Konfiguration, systemd/Quadlet-Dateien oder Dokumentation im Repository reproduzierbar sein.
- Alle Skripte müssen idempotent sein.
- Keine bestehende ZFS-Pool-Struktur zerstören.
- Niemals `zpool create`, `zpool destroy`, `zfs destroy` oder ähnliche destruktive Befehle ausführen, ohne dass eindeutig feststeht, dass dies gewollt ist.
- Vor Änderungen zunächst den Ist-Zustand erfassen.
- Keine geheimen Schlüssel, Passwörter, HF-Tokens oder API-Keys unverschlüsselt in Git committen.
- Nutze stabile, gepinnte Versionen statt `latest`, wo dies sinnvoll möglich ist.
- Bevor du eine Einstellung oder Option verwendest, prüfe die aktuell installierte Version bzw. aktuelle Upstream-Dokumentation.
- Wenn sich Upstream seit dieser Vorgabe geändert hat, verwende die aktuelle kompatible Variante und dokumentiere die Abweichung.
- Ändere funktionierende Systemkonfiguration nicht grundlos.
- Nach jedem größeren Schritt testen.
- Bei Fehlern nicht einfach Workarounds stapeln, sondern Ursache feststellen und dokumentieren.

# 1. Zielarchitektur

Der Rechner läuft unter CachyOS / Arch Linux und besitzt:

- NVIDIA RTX PRO 6000 Blackwell Workstation Edition
- 96 GB VRAM
- NVIDIA Compute Capability SM120
- lokale NVMe-Speicher
- ZFS
- systemd
- Podman als bevorzugte Container Engine

Zielmodell:

`Qwen3.8 Flash-Next`

Für den optimierten Single-GPU-Betrieb auf der RTX PRO 6000 soll zunächst der aktuelle Pennyroyal-Referenzpfad verwendet werden.

Bevorzugtes Modell:

`RadixArk/Qwen3.8-Flash-Next-NVFP4`

Bevorzugte Runtime:

`jpezzulli/sglang-rtxpro6000`

Aktueller Referenzstand zum Zeitpunkt dieser Aufgabenbeschreibung:

- Pennyroyal v2.5.3
- OCI Image `ghcr.io/jpezzulli/sglang-rtxpro6000:v2.5.3`
- Profil `next`
- Flash-Next NVFP4
- FP8 KV Cache
- native NEXTN/MTP
- FR-Spec
- HiCache
- NIXL
- maximale getestete Kontextkonfiguration bis 524288 Tokens

Vor Installation MUSST du prüfen, ob inzwischen eine neuere stabile Pennyroyal-Version existiert.

Wenn neuer:
1. Release Notes lesen.
2. Kompatibilität mit RTX PRO 6000 SM120 prüfen.
3. Modellanforderungen prüfen.
4. Nur dann auf die neuere Version wechseln.
5. Verwendete Version und Commit/Tag in einer Lock-/Versionsdatei dokumentieren.

Nicht automatisch normalen Upstream-SGLang statt Pennyroyal installieren.

# 2. Architekturprinzip

Die Infrastruktur besteht logisch aus:

Clients
    |
    v
LiteLLM Gateway :4000
    |
    v
Pennyroyal / SGLang :8001
    |
    v
Qwen3.8 Flash-Next NVFP4
    |
    v
RTX PRO 6000 96 GB

Zusätzlich:

Prometheus
    |
    +-- Node Exporter
    +-- SMART Exporter
    +-- NVIDIA GPU Exporter/DCGM
    +-- SGLang Metrics
    +-- LiteLLM Metrics
    +-- Podman Metrics soweit sinnvoll
    +-- ZFS Metrics

Grafana
    |
    +-- Host Dashboard
    +-- GPU Dashboard
    +-- ZFS/Storage Dashboard
    +-- LLM/SGLang Dashboard
    +-- LiteLLM/API Dashboard
    +-- Container/Service Dashboard

Logs:
Podman/journald -> Grafana Alloy -> Loki -> Grafana

Zusätzlich:
Dozzle -> einfache Live-Ansicht der Containerlogs

Verwaltung:
Git -> validate -> deploy -> Podman/systemd/Quadlet

Darüber zusätzlich:
Komodo als komfortable Verwaltungsoberfläche, soweit Podman-Kompatibilität zuverlässig funktioniert.

Außerdem:
llmctl -> eigene einfache CLI/TUI zur täglichen Bedienung.

Später:
Azure VM
    ^
    |
autossh Reverse Tunnel
    |
LiteLLM :4000

Der Tunnel darf NICHT direkt den ungeschützten SGLang-Port veröffentlichen.

# 3. Zuerst Preflight durchführen

Erstelle:

`scripts/00-preflight.sh`

Dieses Skript sammelt mindestens:

- CachyOS-/Arch-Version
- Kernel
- CPU
- RAM
- NUMA
- NVIDIA-Treiber
- `nvidia-smi`
- GPU UUID
- GPU VRAM
- CUDA-Kompatibilität
- PCIe Link Speed und Width
- Podman-Version
- crun-Version
- systemd-Version
- ZFS-Version
- vorhandene zpools
- vorhandene datasets
- vorhandene Mountpoints
- freie Speicherkapazität
- Dateisysteme aller relevanten NVMe
- installierte NVIDIA Container Toolkit Version
- verfügbare CDI NVIDIA Devices
- Git-Version
- Python-Version
- vorhandenes `uv`
- Netzwerkports, die bereits benutzt werden

Ausgabe:

`state/preflight-report.txt`

`state/` muss in `.gitignore`.

Zusätzlich menschenlesbare Zusammenfassung auf dem Terminal.

# 4. Repository-Struktur

Räume das bestehende Repository sinnvoll auf.

Ziel ungefähr:

llm-infra-setup/
├── README.md
├── CHANGELOG.md
├── Makefile
├── .gitignore
├── .env.example
├── versions.lock
│
├── config/
│   ├── host.env.example
│   ├── model.env
│   ├── pennyroyal/
│   ├── prometheus/
│   │   ├── prometheus.yml
│   │   └── rules/
│   ├── grafana/
│   │   ├── provisioning/
│   │   └── dashboards/
│   ├── litellm/
│   │   └── config.yaml
│   ├── loki/
│   ├── alloy/
│   ├── dozzle/
│   ├── komodo/
│   └── autossh/
│
├── quadlet/
│   ├── networks/
│   ├── containers/
│   └── volumes/
│
├── systemd/
│   └── user/
│
├── scripts/
│   ├── 00-preflight.sh
│   ├── 10-install-packages.sh
│   ├── 20-zfs-setup.sh
│   ├── 30-nvidia-podman.sh
│   ├── 40-download-model.sh
│   ├── 50-install-pennyroyal.sh
│   ├── 60-monitoring.sh
│   ├── 70-litellm.sh
│   ├── 80-komodo.sh
│   ├── 90-autossh.sh
│   ├── validate.sh
│   ├── deploy.sh
│   ├── healthcheck.sh
│   ├── benchmark.sh
│   └── backup-config.sh
│
├── lib/
│   └── common.sh
│
├── tui/
│   ├── pyproject.toml
│   └── src/llmctl/
│
├── tests/
│
├── docs/
│   ├── ARCHITECTURE.md
│   ├── INSTALL.md
│   ├── OPERATIONS.md
│   ├── TROUBLESHOOTING.md
│   ├── MONITORING.md
│   ├── DISASTER-RECOVERY.md
│   └── SECURITY.md
│
└── state/
    └── gitignored

Passe die Struktur sinnvoll an, wenn technisch nötig, aber halte sie übersichtlich.

# 5. Pakete installieren

Erstelle `scripts/10-install-packages.sh`.

Verwende bevorzugt offizielle CachyOS-/Arch-Repositories.

Benötigt werden mindestens:

- podman
- podman-compose falls sinnvoll
- buildah
- skopeo
- crun
- nvidia-container-toolkit
- git
- git-lfs
- curl
- wget
- jq
- yq
- rsync
- openssh
- autossh
- python
- uv
- age
- sops, wenn verfügbar
- smartmontools
- prometheus-node-exporter
- prometheus-smartctl-exporter
- shellcheck
- yamllint
- make

Prüfe vorher, was bereits installiert ist.

Keine unnötigen Doppelinstallationen.

# 6. Rootless Podman korrekt vorbereiten

Bevorzugt rootless Podman benutzen.

Sicherstellen:

`systemctl --user enable --now podman.socket`

und wenn sinnvoll:

`loginctl enable-linger <aktueller Benutzer>`

NVIDIA-GPU-Zugriff über CDI konfigurieren.

Prüfen:

`nvidia-ctk cdi list`

Dann einen echten GPU-Test mit Podman durchführen.

Sinngemäß muss funktionieren:

`podman run --rm --device nvidia.com/gpu=all ... nvidia-smi`

Nicht blind alte NVIDIA OCI Hook- und CDI-Mechanismen mischen.

Aktuelle NVIDIA-Empfehlung für Podman ist CDI.

Dokumentiere:

- GPU UUID
- CDI Device Name
- funktionierenden Testbefehl

# 7. ZFS Dataset für Modelle

Das Modell MUSS auf einem ZFS Dataset liegen.

Zunächst vorhandene Pools feststellen.

Wenn genau ein geeigneter Datenpool existiert, benutze diesen.

Falls mehrere Pools vorhanden sind, NICHT raten. Dann die möglichen Pools samt freiem Platz ausgeben und den sichersten bereits vorgesehenen Datenpool wählen, wenn dies anhand bestehender Mountpoints/Benennung eindeutig ist.

Keine neuen Pools erstellen.

Zieldataset sinngemäß:

`<POOL>/llm/models`

Mountpoint bevorzugt:

`/srv/llm/models`

Eigenschaften:

- compression=lz4
- atime=off
- recordsize=1M
- xattr=sa, sofern mit bestehender Poolkonfiguration kompatibel

Danach Eigenschaften überprüfen und dokumentieren.

Erstelle:

`scripts/20-zfs-setup.sh`

Das Skript muss mehrfach ausführbar sein.

Zusätzlich nach erfolgreichem Modelldownload einen ZFS Snapshot ermöglichen.

Beispielname:

`<POOL>/llm/models@qwen38-flash-next-<revision>`

WICHTIG:

Das NIXL-Persistenzverzeichnis NICHT automatisch auf dasselbe lz4-Dataset legen.

Pennyroyal/NIXL benötigt einen Datenträger bzw. ein Dateisystem, das die benötigten O_DIRECT/io_uring-Zugriffe sauber unterstützt.

Für NIXL deshalb zunächst einen Funktionstest durchführen.

Bevorzugter Pfad:

`/srv/llm/nixl`

Wenn ZFS hierfür benutzt werden soll, erst O_DIRECT/io_uring testen.

Kein separates Modell-Kompressionsprofil für latency-kritische NIXL-Daten voraussetzen; NIXL bleibt zunächst unter `/srv/llm/nixl` und wird separat getestet.

# 8. Modell herunterladen

Erstelle:

`scripts/40-download-model.sh`

Modell:

`RadixArk/Qwen3.8-Flash-Next-NVFP4`

Ziel ungefähr:

`/srv/llm/models/RadixArk-Qwen3.8-Flash-Next-NVFP4`

Benutze die aktuelle Hugging-Face-CLI.

Kein Modell in `$HOME/.cache/huggingface` verstecken, wenn wir explizit das ZFS Modelldataset besitzen.

Wenn HF_AUTH benötigt wird:

- `HF_TOKEN` ausschließlich aus Secrets laden.
- niemals ins Git schreiben.
- bei fehlender Berechtigung sauber abbrechen.
- nicht eigenmächtig irgendeinen anderen Quant auswählen.

Nach Download:

- Modellrevision erfassen.
- Commit SHA erfassen.
- Dateigröße erfassen.
- `config.json` prüfen.
- Safetensor-Dateien prüfen.
- offensichtliche unvollständige Downloads erkennen.
- Modelldaten in `versions.lock` dokumentieren.
- ZFS Snapshot anbieten/erstellen.

# 9. Pennyroyal installieren

Primärer Weg ist zunächst der veröffentlichte, gepinnte Pennyroyal-OCI-Container.

Nicht sofort selbst SGLang kompilieren, solange der offizielle Pennyroyal-Container den gewünschten Stand sauber unterstützt.

Aktueller Referenzcontainer:

`ghcr.io/jpezzulli/sglang-rtxpro6000:v2.5.3`

Vor Benutzung aktuelle stabile Release prüfen.

Image-Digest zusätzlich erfassen und in `versions.lock` speichern.

Modell-Mount read-only.

Verzeichnisse trennen:

Models:
`/srv/llm/models`

Runtime Cache:
`/srv/llm/cache/pennyroyal`

NIXL:
`/srv/llm/nixl`

Pennyroyal Profil:

`next`

Zunächst den offiziellen FR-Spec-Default möglichst unverändert übernehmen.

API-Port:

`127.0.0.1:8001`

Served Model Name:

`pennyroyal`

Nicht unnötig `0.0.0.0` veröffentlichen.

GPU über NVIDIA CDI an den Podman-Container durchreichen.

Pennyroyal benötigt für NIXL/io_uring gegebenenfalls eine abweichende seccomp-Konfiguration. Übernimm die vom aktuellen Pennyroyal-Container-Guide benötigten Einstellungen so minimal wie möglich.

Nicht einfach `--privileged` verwenden.

# 10. Pennyroyal zuerst als Baseline validieren

Beim ersten funktionierenden Start zunächst KEINE wilden Optimierungen ergänzen.

Baseline testen:

- Container startet
- GPU erkannt
- Modell komplett geladen
- CUDA Graph Capture erfolgreich
- `/health`
- `/v1/models`
- OpenAI Chat Completion
- Streaming
- Reasoning
- Tool Calling
- einfacher Coding Prompt
- lange Eingabe
- mindestens zwei parallele Requests
- Neustart
- NIXL/HiCache-Wiederverwendung, soweit vorgesehen

Resultate speichern unter:

`state/validation/`

Erst wenn Baseline funktioniert, Performanceoptionen testen.

# 11. Online FP8 / Performanceprofil

Pennyroyal unterstützt für Flash-Next optional Online FP8.

Nach erfolgreicher Baseline separat testen:

`SGLANG_SM120_ONLINE_MXFP8=true`

Vorher/Nachher Benchmark durchführen.

Erfassen:

- Load Time
- TTFT
- Prefill tok/s
- Decode tok/s
- Aggregate tok/s bei Parallelität
- VRAM
- Host RAM
- GPU Power
- GPU Temperature
- Fehler
- Output-Korrektheit

Nur aktiv lassen, wenn stabil.

Danach optional C6-Profil untersuchen:

- `MAX_RUNNING_REQUESTS=6`
- `MAX_MAMBA_CACHE_SIZE=36`
- `MAX_TOTAL_TOKENS=1048576`
- CPU Media Preprocessing

Aber erst nach funktionierender Standardkonfiguration.

Das Hauptziel ist zunächst Stabilität und reproduzierbarer Betrieb.

# 12. SGLang Prometheus Metrics

SGLang/Pennyroyal muss Prometheus-Metriken bereitstellen.

Aktuelle SGLang-Optionen prüfen.

Ziel:

`--enable-metrics`

und wenn mit dieser Pennyroyal-Version kompatibel:

`--enable-mfu-metrics`

Nicht blind den Pennyroyal-Launcher zerlegen.

Zuerst prüfen, ob Pennyroyal eine offizielle Möglichkeit für zusätzliche SGLang-Argumente bietet.

Wenn ja: diese verwenden.

Wenn nein:
- minimalen Override erstellen,
- sauber im Repository dokumentieren,
- keine Kopie eines riesigen Upstream-Launchscripts pflegen, wenn es vermeidbar ist.

Nach Start prüfen:

`/metrics`

Prometheus muss die Metriken erfolgreich scrapen.

# 13. Prometheus installieren

Prometheus soll in Podman laufen.

Persistente Daten getrennt halten.

Retention zunächst sinnvoll, z.B.:

30 Tage

oder größenbegrenzt, falls besser.

Prometheus Targets:

- node-exporter
- smartctl-exporter
- NVIDIA GPU exporter
- SGLang
- LiteLLM
- Loki/Alloy relevante Self-Metrics
- Podman/Container-Metriken, soweit sauber verfügbar
- eventuell Komodo Metrics, falls vorhanden

Prometheus selbst nur lokal veröffentlichen.

Bevorzugt:

`127.0.0.1:9090`

Konfiguration komplett aus Git.

`promtool check config` muss Teil von `scripts/validate.sh` sein.

# 14. OS-Metriken

Installiere Node Exporter nativ auf dem Host, wenn das unter CachyOS sauberer ist als ein Container.

Wir wollen echte Hostdaten und nicht versehentlich nur die Containeransicht.

Dashboard muss enthalten:

CPU:
- Gesamtauslastung %
- pro Core
- Load 1/5/15
- Frequenz
- Kontextwechsel
- Interrupts

RAM:
- benutzt
- verfügbar
- Cache
- Swap
- Pressure

Disk:
- Read MB/s
- Write MB/s
- Read IOPS
- Write IOPS
- IO Latency
- Queue
- Filesystem Used %
- freie GiB

Netzwerk:
- RX/TX MB/s
- Packets
- Errors
- Drops

System:
- Uptime
- Processes
- systemd Services falls sinnvoll
- Pressure Stall Information
- Temperaturen soweit verfügbar

Alle Einheiten menschenlesbar.

Also:
- GiB statt Bytes
- MB/s statt Bytes/s
- Millisekunden statt Sekundenbruchteilen, wenn sinnvoll
- Prozentwerte 0-100 %
- Temperaturen °C

# 15. ZFS Monitoring

ZFS sichtbar machen.

Mindestens:

- Pool Health
- Dataset Used/Available
- Compression Ratio
- ARC Size
- ARC Hit Ratio
- ARC Misses
- L2ARC falls vorhanden
- Reads/Writes
- IOPS
- Pool Errors
- Scrub Status soweit verfügbar

Wenn Node Exporter ZFS Collector genügt, verwende ihn.

Keinen zusätzlichen Exporter nur aus Prinzip installieren.

# 16. SMART/NVMe Monitoring

Smartctl Exporter aktivieren.

Dashboard:

- Modell
- Seriennummer nur soweit lokal sinnvoll
- Temperatur
- Percentage Used
- Available Spare
- Media Errors
- Unsafe Shutdowns
- Data Read/Written
- Critical Warning

Keine Alarmhysterie bei normalen Rohwerten.

# 17. NVIDIA GPU Monitoring

Bevorzugt NVIDIA DCGM Exporter, sofern die installierte RTX PRO 6000 Workstation und aktuelle Treiber/DCGM-Kombination damit sauber funktioniert.

Falls DCGM auf dieser Workstation unnötig problematisch ist, verwende einen stabilen Prometheus NVIDIA-SMI-Exporter.

Dashboard mindestens:

- GPU Utilization %
- VRAM Used GiB
- VRAM Total GiB
- VRAM %
- Power Draw W
- Power Limit W
- Temperature °C
- Fan %
- GPU Clock MHz
- Memory Clock MHz
- PCIe RX MB/s
- PCIe TX MB/s
- Encoder/Decoder falls vorhanden
- ECC falls verfügbar
- Performance State
- Throttling Reasons, soweit verfügbar

Oben große Stat-Panels:

GPU Load
VRAM
Power
Temperature
LLM Tokens/s

# 18. Eigenes SGLang / LLM Grafana Dashboard

Nicht nur irgendein importiertes Dashboard übernehmen.

Erstelle ein eigenes ordentliches Dashboard.

Name:

`LLM - Qwen3.8 Flash-Next / Pennyroyal`

Bereiche:

Overview:
- API status
- Modellname
- Uptime
- Requests/s
- Running Requests
- Waiting Requests
- Prompt tok/s
- Generation tok/s
- Total tok/s

Latency:
- TTFT p50
- TTFT p95
- TTFT p99
- Inter-Token Latency / TPOT
- End-to-End Latency

Tokens:
- Prompt Tokens total
- Generated Tokens total
- Prompt Tokens/s
- Generated Tokens/s
- Token Usage %

Cache:
- Cache Hit Rate %
- Cached Tokens
- KV Usage soweit vorhanden
- HiCache relevante Metriken soweit exportiert

Performance:
- geschätzte TFLOPS/GPU, wenn `--enable-mfu-metrics`
- geschätzte Memory Read GB/s
- geschätzte Memory Write GB/s
- GPU Utilization
- VRAM
- Power

Concurrency:
- aktive Requests
- Queue
- Request Rate
- Fehler

Alle Grafana-Panels:
- sinnvoll benennen
- Beschreibung/Tooltip
- sinnvolle Units
- vernünftige Min/Max
- keine unnötigen Dezimalstellen
- bei Prozentwerten Prozent
- Bytes automatisch als IEC
- Tokenraten als tokens/s

Dashboard JSON ins Git.

Grafana muss Dashboards automatisch provisionieren.

Kein manuelles Klicken als notwendiger Installationsschritt.

# 19. Grafana

Grafana als Podman Container.

Port:

`127.0.0.1:3000`

Provisionieren:

- Prometheus datasource
- Loki datasource
- Dashboards
- Dashboard folders

Verzeichnisse:

Host
GPU
Storage
Containers
LLM
API

Admin-Passwort als Secret.

Nicht in Git.

# 20. Loki + Grafana Alloy

Wir wollen neben Dozzle auch historische Logs.

Loki als Podman Service.

Grafana Alloy sammelt mindestens:

- journald
- Pennyroyal Logs
- relevante Podman Container Logs
- LiteLLM Logs
- GitOps/Deploy Logs
- autossh Logs

Labels nicht explodieren lassen.

Keine Request-Prompts oder Modellantworten standardmäßig loggen.

Datenschutz und Speicherverbrauch beachten.

Retention vernünftig begrenzen.

# 21. Dozzle

Installiere Dozzle für den schnellen täglichen Blick auf Containerlogs.

Rootless Podman Socket read-only mounten.

Nur lokal binden.

Beispiel:

`127.0.0.1:8080`

Dozzle ist für:
- Live Logs
- Container auswählen
- Fehler schnell ansehen

Es ist nicht die dauerhafte Logdatenbank. Dafür Loki.

# 22. LiteLLM Gateway

LiteLLM installieren.

Zweck:

Clients sollen später NICHT direkt gegen SGLang laufen.

Normaler Datenpfad:

Client
 -> LiteLLM
 -> Pennyroyal/SGLang

LiteLLM Port:

`127.0.0.1:4000`

Lokales Modell bekommt einen einfachen Alias:

`qwen-local`

Backend:

Pennyroyal OpenAI API auf Port 8001.

SGLang selbst benötigt lokal zunächst keinen öffentlich bekannten API-Key, weil es nur auf localhost erreichbar sein soll.

LiteLLM benötigt für Virtual Keys eine PostgreSQL-Datenbank.

Deshalb kleinen PostgreSQL-Container nur für LiteLLM bereitstellen.

Persistente Daten verwenden.

Master Key sicher generieren.

Nicht committen.

LiteLLM konfigurieren für:

- Virtual Keys
- Benutzer/Teams später
- Token Tracking
- Rate Limits
- Request Counts
- Spend/Usage Tracking soweit sinnvoll
- Modellzugriff
- Prometheus Metrics

Prometheus-Metrics aktivieren.

Wenn möglich separaten Metrics-Port verwenden und NICHT extern veröffentlichen.

Grafana LiteLLM Dashboard:

- Requests/s
- erfolgreiche Requests
- Fehler
- p50/p95/p99
- Prompt Tokens
- Completion Tokens
- Tokens pro User/Key soweit ohne Secrets darstellbar
- Rate-limit Events
- Backend Health
- Pennyroyal Upstream Status

# 23. Secrets

Bevorzugter Mechanismus:

SOPS + age.

Age-Key ausschließlich lokal:

`~/.config/sops/age/keys.txt`

Git darf ausschließlich verschlüsselte Secretdateien enthalten.

Alternativ, falls SOPS auf diesem System Probleme verursacht:

`~/.config/llm-infra/secrets.env`

mit:

`chmod 600`

Dann nur `.example` ins Git.

Zu Secrets gehören:

- HF_TOKEN
- GRAFANA_ADMIN_PASSWORD
- LITELLM_MASTER_KEY
- PostgreSQL Password
- Komodo Secrets
- SSH Key Referenzen
- zukünftige Azure Credentials

Kein Secret darf bei `set -x`, Logs oder `llmctl status` ausgegeben werden.

# 24. Komodo

Komodo soll als komfortable Web-Verwaltungsoberfläche eingerichtet werden.

Ziele:

- Container sehen
- Logs
- Start/Stop/Restart
- Deployments
- Git Repo integrieren
- Deploy Status
- Updates sichtbar
- Webhooks bei Git Push

ABER:

Komodo verwendet primär Docker-/Compose-Semantik und Podman-Kompatibilität ist nicht vollständig identisch.

Deshalb zuerst eine Kompatibilitätsprüfung durchführen.

Prüfen:

- Podman Socket
- Docker API compatibility
- Stack discovery
- Start
- Stop
- Restart
- Logs
- compose deployment
- image pull
- recreate
- reboot persistence

Wenn das stabil funktioniert:

Komodo mit Repo `llm-infra-setup` verbinden.

Pushes auf `main` dürfen nach erfolgreicher Validierung automatisch deployen.

Wenn Komodo auf dieser Podman-Version einen bekannten Fehler zeigt:

NICHT Docker zusätzlich installieren und dadurch eine zweite Containerwelt erzeugen, nur um Komodo glücklich zu machen.

Dann:

- Komodo für Monitoring/Bedienung verwenden, soweit stabil
- GitOps Deployment über unsere eigene systemd-Lösung durchführen

Dokumentiere das Ergebnis in:

`docs/KOMODO.md`

# 25. GitOps Deployment

Git ist Source of Truth.

Der Branch `main` entspricht dem gewünschten produktiven Zustand.

Erstelle:

`scripts/validate.sh`

Validierung mindestens:

- shellcheck
- yamllint
- JSON Validity
- Prometheus config
- Grafana JSON
- Quadlet Syntax soweit prüfbar
- erforderliche Env-Variablen
- keine Secrets im Git
- Modellpfad existiert
- benötigte Ports verfügbar bzw. erwartete Services laufen dort

Erstelle:

`scripts/deploy.sh`

Ablauf:

1. Lock setzen, damit keine zwei Deployments parallel laufen.
2. aktuelle Git Revision erfassen.
3. validate
4. Konfiguration rendern
5. Quadlet-Dateien installieren/aktualisieren
6. systemd daemon-reload
7. nur geänderte Services neu starten/recreaten
8. Healthchecks
9. Ergebnis loggen
10. bei Fehlschlag klare Fehlermeldung
11. soweit möglich vorherigen funktionierenden Zustand erhalten

Deployment muss idempotent sein.

Kein `podman system prune -a` oder andere Vorschlaghammermethoden.

# 26. Native GitOps-Fallback

Da Komodo/Podman nicht unsere einzige Abhängigkeit sein darf, baue einen nativen Weg.

Systemd User Service:

`llm-infra-deploy.service`

Optional:

`llm-infra-gitops.timer`

Dieser kann regelmäßig:

`git fetch`

prüfen, ob `origin/main` neuer ist.

Nur bei Änderung:

- `git pull --ff-only`
- validate
- deploy

Kein automatischer Merge.

Keine Force-Resets lokaler Änderungen.

Bei Dirty Working Tree:
- Deployment abbrechen
- sichtbar melden

Optional zusätzlich `.path` Unit für lokale Änderungen/Commits.

Deployment nur für committed state.

# 27. Autossh für spätere Azure-Anbindung

Jetzt komplett vorbereiten, aber standardmäßig deaktivieren.

Konfiguration:

`TUNNEL_ENABLED=false`

Dummy-Werte:

`AZURE_SSH_HOST=192.0.2.10`

Das ist absichtlich eine Dokumentations-/Dummy-IP.

Weitere Defaults:

`AZURE_SSH_USER=llm-tunnel`
`AZURE_SSH_PORT=22`
`AZURE_REMOTE_PORT=14000`
`LOCAL_LITELLM_HOST=127.0.0.1`
`LOCAL_LITELLM_PORT=4000`

Ziel ist später ein Reverse SSH Tunnel:

Azure localhost:<remote port>
 ->
lokales LiteLLM :4000

NICHT direkt SGLang :8001.

Remote Binding standardmäßig nur:

`127.0.0.1`

Keine öffentliche `0.0.0.0`-Freigabe.

Autossh Optionen:

- BatchMode=yes
- ServerAliveInterval
- ServerAliveCountMax
- ExitOnForwardFailure=yes
- keine Passwortauthentifizierung
- eigener SSH Key
- known_hosts Prüfung aktiv
- automatische Wiederverbindung

Systemd User Service:

`llm-autossh.service`

Nur aktivieren, wenn:

`TUNNEL_ENABLED=true`

TUI soll Tunnelstatus zeigen.

Später soll man nur die Git-Konfiguration ändern müssen.

# 28. Eigene llmctl CLI/TUI

Programmiere eine kleine Verwaltungssoftware.

Name:

`llmctl`

Technik:

Python
Typer für CLI
Textual für TUI
Rich für Ausgabe

Projekt unter:

`tui/`

Installation bevorzugt über:

`uv tool install ...`

oder Wrapper im Repo.

Aufruf:

`llmctl`

startet die TUI.

Zusätzlich CLI:

`llmctl status`
`llmctl health`
`llmctl start`
`llmctl stop`
`llmctl restart`
`llmctl logs`
`llmctl deploy`
`llmctl update`
`llmctl benchmark`
`llmctl model`
`llmctl tunnel`
`llmctl urls`

Die TUI soll bewusst sehr einfach sein.

Startseite:

HOST
- CPU Load
- RAM
- Disk
- ZFS Health

GPU
- GPU %
- VRAM
- Temperatur
- Watt

LLM
- Running/Stopped
- Modell
- API Health
- Requests
- Tokens/s
- TTFT
- Cache Hit

INFRA
- Prometheus
- Grafana
- Loki
- LiteLLM
- Dozzle
- Komodo

GIT
- Branch
- Commit
- Dirty ja/nein
- letzter Deploy
- Update verfügbar

TUNNEL
- Disabled
- Connected
- Error

Buttons/Actions:

[F1] Help
[S] Start
[X] Stop
[R] Restart
[L] Logs
[D] Deploy
[B] Benchmark
[T] Tunnel
[U] Update Status
[G] Grafana
[K] Komodo
[O] Dozzle
[Q] Quit

Keine destruktive Aktion ohne Bestätigung.

Für normalen Start/Restart keine fünf Rückfragen.

Logs auswählbar:

- Pennyroyal
- LiteLLM
- Prometheus
- Grafana
- Loki
- Komodo
- autossh
- deploy

TUI darf keine Root-Shell benötigen.

Root-Aktionen nur über klar begrenzte vorbereitete Mechanismen.

# 29. Makefile

Erstelle einfache Kommandos:

`make preflight`
`make install`
`make validate`
`make deploy`
`make health`
`make start`
`make stop`
`make restart`
`make logs`
`make benchmark`
`make model-download`
`make dashboards`
`make status`

`make install` soll nicht ungefragt destruktive Speicheroperationen durchführen.

# 30. Healthchecks

Erstelle:

`scripts/healthcheck.sh`

Ausgabe mit grün/gelb/rot.

Prüfen:

Host:
- ZFS healthy
- genügend Disk
- NVIDIA erreichbar

Podman:
- Socket
- GPU CDI

Pennyroyal:
- Container/Service
- API `/health`
- Modell

LiteLLM:
- API
- Backend qwen-local erreichbar

Monitoring:
- Prometheus
- alle Targets
- Grafana
- Loki

Operations:
- Komodo
- Dozzle

Tunnel:
- disabled ist OK
- wenn enabled: SSH-Verbindung prüfen

Am Ende:

`SYSTEM HEALTHY`

nur wenn kritische Komponenten tatsächlich funktionieren.

# 31. Benchmark-Skript

`scripts/benchmark.sh`

Mindestens drei Profile:

QUICK
- kurzer Prompt
- 256-512 Output Tokens

NORMAL
- ca. 8K Input
- ca. 1024 Output

LONG
- mindestens 64K Input
- 1024 Output

Zusätzlich concurrency:

1
2
4

Später optional 6.

Erfassen:

- TTFT
- Prefill tok/s
- Decode tok/s
- Aggregate tok/s
- Gesamtzeit
- VRAM
- Power
- Fehler

Ergebnisse:

`state/benchmarks/<timestamp>.json`
`state/benchmarks/<timestamp>.md`

`state` nicht committen.

Eine kleine `docs/BENCHMARKS.md` darf ausgewählte validierte Ergebnisse enthalten.

# 32. Grafana Alerts

Lege sinnvolle Warnungen an.

Beispiele:

CRITICAL:
- Pennyroyal down
- LiteLLM down
- ZFS pool unhealthy
- NVMe critical warning
- GPU nicht erreichbar

WARNING:
- GPU > 90 °C über längere Zeit
- Filesystem > 90 %
- RAM > 95 %
- Swap stark aktiv
- TTFT ungewöhnlich hoch
- API Error Rate hoch
- NIXL Storage fast voll

Keine Warnung wegen eines einzelnen kurzen Peaks.

# 33. README

README soll nach der Installation so einfach sein, dass man Monate später nicht wieder Archäologie betreiben muss.

Ganz oben:

Quick Start

```
llmctl
```

oder:

```
make status
make start
```

Dann URLs:

Grafana
LiteLLM
Dozzle
Komodo
Prometheus

Nur localhost URLs dokumentieren, solange nichts bewusst im LAN freigegeben wurde.

Außerdem:

- Architektur
- Modell
- verwendete Versionen
- Datenpfade
- Services
- Updateprozess
- Troubleshooting
- Backup
- Azure Tunnel später aktivieren

# 34. Version Lock

Erstelle `versions.lock`.

Darin mindestens:

CachyOS Kernel
NVIDIA Driver
Podman
crun
NVIDIA Container Toolkit
Pennyroyal Tag
Pennyroyal Image Digest
Pennyroyal Git Commit
Qwen Model ID
Qwen Model Revision
Prometheus
Grafana
Loki
Alloy
LiteLLM
PostgreSQL
Komodo
Dozzle

Keine Secrets.

# 35. Sicherheit

Standardmäßig ausschließlich localhost Ports.

Keinen Service unnötig öffentlich öffnen.

Insbesondere NICHT öffentlich:

8001 SGLang
9090 Prometheus
PostgreSQL
Podman Socket

Der Podman Socket darf nur dort gemountet werden, wo zwingend nötig.

Dozzle und Komodo bekommen nur die Rechte, die wirklich gebraucht werden.

SGLang Request Logging standardmäßig ohne Prompt-/Response-Inhalte.

LiteLLM Keys niemals in Logs ausgeben.

# 36. Backup / Disaster Recovery

Zu sichern sind NICHT zwingend die riesigen Modelldateien, da diese reproduzierbar heruntergeladen werden können.

Sichern:

- Git Repo
- versions.lock
- Grafana Dashboard Source
- LiteLLM/PostgreSQL Daten
- secrets verschlüsselt bzw. separat
- Komodo Konfiguration
- relevante service state/config

Modelldataset ist durch ZFS Snapshot geschützt.

Dokumentiere Wiederherstellung.

# 37. Zusätzliche sinnvolle Erweiterungen

Bereite Architektur so vor, dass später leicht ergänzt werden können:

- zweites Modell
- zweiter GPU-Host
- Azure LLM Fallback
- zweites Pennyroyal Backend
- Load Balancing
- SGLang Router
- OpenTelemetry/Tempo
- externe Alert Notifications
- Qwen Code / Codex / OpenCode Clients
- API-Key pro Agent
- Agent-spezifische LiteLLM Limits

Aber diese Dinge NICHT unnötig jetzt installieren.

# 38. Betriebsphilosophie

Die tägliche Bedienung soll am Ende ungefähr so aussehen:

```
llmctl
```

und nicht:

```
sudo podman inspect ...
journalctl ...
grep ...
curl ...
systemctl ...
```

Natürlich dürfen diese Werkzeuge intern benutzt werden.

Aber der Besitzer des Systems soll die häufigen Aufgaben über `llmctl`, Grafana, Dozzle oder Komodo erledigen können.

# 39. Installationsreihenfolge

Arbeite in dieser Reihenfolge:

PHASE 1
Ist-Zustand und Preflight

PHASE 2
Repository-Struktur und Basisskripte

PHASE 3
Podman + NVIDIA CDI

PHASE 4
ZFS Modelldataset

PHASE 5
Modelldownload

PHASE 6
Pennyroyal Baseline

PHASE 7
Pennyroyal Validation

PHASE 8
Prometheus + Host Exporter + GPU Metrics

PHASE 9
Grafana + eigene Dashboards

PHASE 10
Loki + Alloy + Dozzle

PHASE 11
LiteLLM + PostgreSQL + Virtual Keys

PHASE 12
Komodo

PHASE 13
GitOps Deployment

PHASE 14
autossh Vorbereitung

PHASE 15
llmctl TUI

PHASE 16
End-to-End Test

PHASE 17
Dokumentation

# 40. Abschlussprüfung

Die Aufgabe gilt erst als erfolgreich abgeschlossen, wenn folgende Tests bestanden sind:

1. Nach Reboot starten die gewünschten Dienste automatisch.
2. `nvidia-smi` funktioniert auf dem Host.
3. GPU funktioniert aus dem Pennyroyal Podman Container.
4. Modell liegt auf ZFS mit `compression=lz4`.
5. Qwen3.8 Flash-Next antwortet.
6. OpenAI-kompatible API funktioniert.
7. LiteLLM erreicht Pennyroyal.
8. LiteLLM Virtual Key funktioniert.
9. direkter SGLang-Port ist nicht extern veröffentlicht.
10. Prometheus hat alle kritischen Targets UP.
11. Grafana zeigt Hostmetriken.
12. Grafana zeigt GPU-Metriken.
13. Grafana zeigt SGLang-Metriken.
14. Grafana zeigt Tokens/s und TTFT verständlich.
15. Grafana zeigt ZFS/Storage.
16. Loki enthält Service Logs.
17. Dozzle zeigt Podman Logs.
18. `llmctl status` funktioniert.
19. `llmctl restart` funktioniert.
20. `llmctl logs` funktioniert.
21. `llmctl benchmark` funktioniert.
22. `make validate` läuft fehlerfrei.
23. `make deploy` ist idempotent.
24. Git enthält keine Secrets.
25. Komodo wurde auf Podman getestet und Status dokumentiert.
26. autossh-Konfiguration existiert, ist aber wegen Dummy-IP deaktiviert.
27. Nach einem zweiten `make deploy` entstehen keine unnötigen Änderungen.
28. README reicht aus, um das System nach Monaten wieder bedienen zu können.

# 41. Vorgehensweise während deiner Arbeit

Zeige mir nach jedem größeren PHASE-Abschluss kurz:

- was du gefunden hast
- was du geändert hast
- welche Dateien du erzeugt/geändert hast
- Testergebnis
- eventuelle Abweichungen von dieser Vorgabe

Arbeite danach selbstständig mit der nächsten Phase weiter.

Nicht wegen jeder Kleinigkeit nachfragen.

Wenn eine Entscheidung reversibel und ungefährlich ist, triff eine sinnvolle technische Entscheidung und dokumentiere sie.

Nur bei wirklich destruktiven oder nicht eindeutig rückgängig zu machenden Aktionen stoppen.

Vor allem:
KEIN ZFS-Pool zerstören oder neu formatieren.

Am Ende zeige:

- finale Architektur
- verwendete Versionen
- Services
- Ports
- Datenpfade
- Git Status
- Healthcheck
- Benchmark
- Links/URLs
- noch offene Punkte

Das Endziel lautet:

Ein stabiler, reproduzierbarer, möglichst einfacher lokaler Qwen3.8-Flash-Next-Server auf der RTX PRO 6000, dessen komplette Infrastruktur über Git verwaltet wird und den der Benutzer im Alltag hauptsächlich über `llmctl`, Grafana, Dozzle und Komodo bedienen kann.

# 42. ZWINGENDE Git-, Commit-, Dokumentations- und Reproduzierbarkeitsregeln

Das Repository `llm-infra-setup` ist die vollständige Source of Truth für dieses System.

Es darf KEINE dauerhafte Infrastrukturänderung geben, die ausschließlich manuell auf dem Rechner vorgenommen wurde und nicht aus dem Repository reproduziert werden kann.

## 42.1 Everything as Code

Alles, was dauerhaft zum System gehört, muss im Repository abgebildet werden.

Dazu gehören insbesondere:

- Paketinstallation
- Paketkonfiguration
- ZFS Dataset-Konfiguration
- Podman-Konfiguration
- NVIDIA-CDI-Konfiguration, soweit lokal erzeugbar
- Container
- Container Networks
- Container Volumes
- Quadlets
- systemd Units
- Pennyroyal-Konfiguration
- Modellkonfiguration
- LiteLLM
- PostgreSQL für LiteLLM
- Prometheus
- Exporter
- Grafana
- Grafana Datasources
- Grafana Dashboards
- Loki
- Alloy
- Dozzle
- Komodo
- GitOps
- autossh
- Healthchecks
- Benchmarks
- llmctl
- Backup/Restore
- Update- und Rollback-Prozeduren

Wenn eine Einstellung technisch nicht direkt versioniert werden kann, muss mindestens ein idempotentes Skript existieren, das diese Einstellung reproduzierbar erzeugt.

Keine wichtigen Installationsschritte dürfen nur in Shell History existieren.

## 42.2 Keine manuellen Einmalbefehle ohne Script

Bevor du einen dauerhaften administrativen Befehl ausführst, prüfe:

Kann dieser Vorgang sinnvoll gescriptet werden?

Wenn ja:

1. Script im Repository erstellen oder vorhandenes Script erweitern.
2. Script validieren.
3. Script ausführen.
4. Ergebnis überprüfen.
5. Dokumentation aktualisieren.
6. Änderungen committen.

Nicht zuerst manuell konfigurieren und das Script irgendwann später nachbauen.

Ausnahmen sind erlaubt für:

- Diagnose
- Read-only-Abfragen
- einmalige Tests
- Debugging

Wenn aus einem Debugging-Schritt eine dauerhafte Konfiguration entsteht, muss diese anschließend in Code überführt werden.

## 42.3 Idempotenz

Jedes Setup- und Deploy-Skript muss möglichst idempotent sein.

Das bedeutet:

Mehrfaches Ausführen darf nicht:

- Konfiguration duplizieren
- Daten zerstören
- Benutzer mehrfach anlegen
- Container vervielfachen
- systemd Units duplizieren
- ZFS Datasets neu erzeugen
- Secrets überschreiben
- unnötige Downloads verursachen

Der gewünschte Endzustand muss geprüft werden, bevor eine Änderung vorgenommen wird.

## 42.4 Commit nach jeder abgeschlossenen Phase

Nach JEDER erfolgreich abgeschlossenen Installationsphase:

1. Tests ausführen.
2. `git diff` überprüfen.
3. sicherstellen, dass keine Secrets enthalten sind.
4. Dokumentation aktualisieren.
5. `versions.lock` aktualisieren, falls relevant.
6. `CHANGELOG.md` aktualisieren, falls relevant.
7. Commit erzeugen.

Es darf nicht erst am Ende ein gigantischer Sammelcommit entstehen.

Bevorzugte Commit-Struktur beispielsweise:

`chore: initialize llm infrastructure repository`

`feat: add host preflight and validation`

`feat: configure rootless podman and nvidia cdi`

`feat: add zfs model dataset provisioning`

`feat: add reproducible qwen model download`

`feat: deploy pennyroyal inference runtime`

`feat: add prometheus monitoring`

`feat: add grafana provisioning and dashboards`

`feat: add loki alloy and dozzle logging`

`feat: add litellm gateway and postgres`

`feat: integrate komodo management`

`feat: add gitops deployment workflow`

`feat: prepare autossh azure tunnel`

`feat: add llmctl management tui`

`docs: complete operations and recovery documentation`

Commit Messages auf Englisch.

Dokumentation darf Deutsch sein.

Code, Variablennamen und technische Bezeichner bevorzugt Englisch.

## 42.5 Commit nur bei erfolgreichem Zustand

Ein normaler Feature-Commit darf nur erzeugt werden, wenn die zugehörige Phase erfolgreich validiert wurde.

Vor jedem Commit mindestens:

```text
make validate
```

Wenn für die Phase ein spezieller Test existiert, diesen ebenfalls ausführen.

Beispiel:

GPU-Phase:
GPU Container Test erfolgreich.

Pennyroyal:
Healthcheck + echter Inference Request erfolgreich.

Monitoring:
Prometheus Targets UP.

Grafana:
Provisioning erfolgreich.

LiteLLM:
echter Request über LiteLLM zu Pennyroyal erfolgreich.

Ein nicht funktionierender Zwischenstand darf nur dann committed werden, wenn dies ausdrücklich als WIP-/Debug-Commit notwendig ist.

## 42.6 Git darf niemals Secrets enthalten

Vor jedem Commit automatisiert prüfen auf:

- HF Tokens
- API Keys
- LiteLLM Master Keys
- PostgreSQL Passwords
- Grafana Passwords
- SSH Private Keys
- Komodo Secrets
- Azure Secrets

Implementiere dafür möglichst zusätzlich einen Secret Scanner.

Bevorzugt:

`gitleaks`

oder vergleichbares Werkzeug.

`make validate` muss den Secret Scan beinhalten.

Ein Secret, das einmal committed wurde, gilt als kompromittiert und muss ersetzt werden.

## 42.7 Versionsmanagement

Alle relevanten Versionen müssen reproduzierbar festgehalten werden.

Datei:

`versions.lock`

Mindestens:

- CachyOS Build
- Kernel
- NVIDIA Driver
- CUDA Compatibility
- Podman
- crun
- NVIDIA Container Toolkit
- Pennyroyal Version
- Pennyroyal Git Commit
- Pennyroyal OCI Image
- OCI Image Digest
- Qwen Model ID
- Hugging Face Revision SHA
- Python
- uv
- LiteLLM
- PostgreSQL
- Prometheus
- Grafana
- Loki
- Alloy
- Dozzle
- Komodo
- Exporter-Versionen

Bei OCI Images möglichst NICHT nur:

`:latest`

verwenden.

Bevorzugt:

Version Tag + Digest.

Beispiel:

`image:tag@sha256:...`

Dadurch muss ein späteres Deployment exakt denselben Stand reproduzieren können.

## 42.8 Konfiguration versionieren

Konfigurationen gehören ins Repository.

Beispiele:

`config/prometheus/prometheus.yml`

`config/grafana/provisioning/...`

`config/grafana/dashboards/...`

`config/litellm/config.yaml`

`config/loki/...`

`config/alloy/...`

`quadlet/...`

`systemd/user/...`

Keine kritische Konfiguration darf ausschließlich über Web-UIs erzeugt werden.

Wenn Grafana über die GUI geändert wird:

Änderung anschließend exportieren und ins Repository übernehmen.

Wenn Komodo eine relevante Konfiguration erzeugt:

soweit technisch möglich ebenfalls als Code/Definition im Repository halten.

Die Git-Version ist die maßgebliche Version.

## 42.9 Dokumentation ist Bestandteil des Features

Ein Feature gilt NICHT als fertig, solange seine Dokumentation fehlt.

Bei jeder relevanten Änderung prüfen:

Muss geändert werden:

- README.md
- docs/ARCHITECTURE.md
- docs/INSTALL.md
- docs/OPERATIONS.md
- docs/MONITORING.md
- docs/TROUBLESHOOTING.md
- docs/SECURITY.md
- docs/DISASTER-RECOVERY.md
- CHANGELOG.md

Dokumentiere insbesondere nicht offensichtliche Entscheidungen mit:

- Was wurde entschieden?
- Warum?
- Welche Alternative wurde verworfen?
- Welche Konsequenzen hat die Entscheidung?
- Wie kann sie später geändert werden?

## 42.10 Architecture Decision Records

Lege zusätzlich an:

`docs/adr/`

Für wichtige Architekturentscheidungen ADRs erzeugen.

Beispiele:

`0001-use-rootless-podman.md`

`0002-use-pennyroyal-for-rtx-pro-6000.md`

`0003-use-litellm-as-api-gateway.md`

`0004-use-quadlet-as-runtime-source-of-truth.md`

`0005-use-komodo-as-management-layer.md`

`0006-separate-model-and-nixl-zfs-storage.md`

`0007-use-prometheus-grafana-loki-stack.md`

Jedes ADR enthält:

- Status
- Kontext
- Entscheidung
- Alternativen
- Konsequenzen

## 42.11 Automatische Repository-Qualitätsprüfung

Erstelle eine zentrale Prüfung:

`scripts/validate.sh`

und:

`make validate`

Diese soll mindestens prüfen:

- Shellcheck
- YAML
- JSON
- Python linting
- Python tests
- Prometheus config
- Grafana JSON
- Quadlet-Dateien
- systemd Units soweit möglich
- `.env.example` vollständig
- notwendige Dateien vorhanden
- keine Secrets
- keine versehentlichen großen Binärdateien
- keine Modelldateien im Git
- keine Runtime Logs im Git
- keine Datenbanken im Git
- keine Cache-Dateien im Git

## 42.12 Pre-Commit Hooks

Richte optional, aber bevorzugt, `pre-commit` ein.

Mindestens:

- trailing whitespace
- end-of-file fixer
- YAML validation
- JSON validation
- shellcheck
- Python linting
- Secret Scan

Konfiguration:

`.pre-commit-config.yaml`

Die Hooks dürfen die zentrale CI-/Validate-Prüfung ergänzen, aber nicht ersetzen.

## 42.13 Reproduzierbarkeitstest

Am Ende muss beantwortet werden können:

"Wenn dieser Rechner morgen komplett neu installiert wird, welche Dinge brauche ich außer dem Git-Repository, meinen Secrets und den großen Modelldaten?"

Zielantwort:

Nur:

1. CachyOS Basissystem
2. Git Repository
3. lokale Secrets/age Key
4. Modell kann reproduzierbar erneut heruntergeladen werden
5. `make install`
6. `make deploy`

Danach muss die Infrastruktur wieder entstehen.

Manuelle Erinnerung des Administrators darf keine Voraussetzung sein.

## 42.14 GitOps-Prinzip

Der gewünschte Zustand lebt in Git.

Daraus folgt:

Git
-> Validate
-> Deploy
-> Healthcheck
-> Running State

Nicht:

Web UI
-> manuell ändern
-> irgendwann vielleicht Git aktualisieren

Änderungen über Komodo oder andere Verwaltungsoberflächen dürfen nicht dauerhaft von Git abweichen.

Wenn eine Änderung dauerhaft sein soll:

1. im Repository ändern
2. committen
3. deployen

Komodo ist Management- und Deploymentoberfläche.

Git bleibt Source of Truth.

## 42.15 Abschlussbericht pro Phase

Nach jeder Phase ausgeben:

PHASE:
STATUS:
COMMIT:
FILES CHANGED:
VERSIONS:
TESTS:
DOCUMENTATION:
OPEN ISSUES:

Beispiel:

PHASE: Pennyroyal Baseline
STATUS: PASS
COMMIT: a1b2c3d feat: deploy pennyroyal inference runtime
FILES CHANGED: 7
TESTS: 8/8 PASS
DOCUMENTATION: updated
OPEN ISSUES: none

Erst danach mit der nächsten Phase fortfahren.

# Oberste Regel

Wenn nach Abschluss irgendeine wichtige Systemeinstellung nur deshalb funktioniert, weil sie irgendwann manuell auf diesem Rechner eingegeben wurde und nicht aus `llm-infra-setup` reproduzierbar ist, ist die Aufgabe NICHT abgeschlossen.

# mkdocs

# MkDocs

Achte generell auf eine saubere, vollständige und fortlaufend gepflegte Dokumentation mit Markdown-Dateien im Repository. Die Dokumentation ist Bestandteil der Implementierung und muss bei relevanten Änderungen immer mit aktualisiert und gemeinsam mit dem Code committed werden. Erstelle mit **MkDocs** eine übersichtliche, moderne Dokumentationsseite in **Deutsch und Englisch**, mit klarer Navigation, Suchfunktion, Inhaltsverzeichnissen, Codebeispielen, Architekturdiagrammen, Screenshots und anschaulichen **animierten GIFs** für typische Abläufe wie Installation, Deployment, `llmctl`, Komodo, Grafana und Fehleranalyse. Bilder, Diagramme und GIFs müssen ebenfalls strukturiert im Repository versioniert werden. Die MkDocs-Konfiguration, Themes, Plugins und Abhängigkeiten müssen reproduzierbar im Repository definiert und versioniert sein. Die Dokumentation soll lokal mit einem einfachen Kommando wie `make docs` oder `mkdocs serve` startbar und mit `make docs-build` vollständig validierbar/buildbar sein. Vermeide Dokumentation, die nur beschreibt, *was* existiert; dokumentiere auch **warum Entscheidungen getroffen wurden, wie Komponenten zusammenarbeiten, wie typische Betriebsaufgaben durchgeführt werden und wie Fehler behoben werden**.



