# WSL / P16 Gen2: Migration und Sicherungsgrenzen

Stand: 2026-10-06. Der Betreiber will den gesamten Arbeitsstand auf den
anderen PC uebernehmen. Optimierung und GPU-Experimente sind dafuer pausiert.
Dies ist eine Wiederherstellungsanleitung, keine Behauptung, dass der
Blackwell-Stack auf der unbekannten Zielhardware schon laeuft.

## Gesicherte Quellen und Worktrees

Alle 13 Git-Arbeitsverzeichnisse unter `~/work` wurden inventarisiert; sie
gehoeren zu neun unterschiedlichen Git-Repositories. Fuenf Infra-Verzeichnisse
teilen dieselbe Git-Datenbank. Branches werden erhalten, nicht vermischt.
Die drei unveraenderten Research-Clones haben keine lokalen Aenderungen;
ihre Upstream-URLs und exakten Revisionen stehen im Repo-Manifest.

| Pfad unter `~/work` | Branch / Zweck |
|---|---|
| `llm-infra-setup` | `turbo-c6-production`, Basis-Infra und Migrationsanker |
| `llm-infra-setup-pennyroyal` | `pennyroyal-plugin-variant`, Produktionsreferenz |
| `llm-infra-setup-turbo-upstream` | `turbo-upstream-ple-graph`, archivierter Versuch |
| `llm-infra-setup-variant-b` | `variant-b-mmap-pagecache`, inkl. liegengebliebenem `TURBO_SPECULATIVE=off` |
| `llm-infra-setup-variant-d` | `variant-d-staging-double-buffer`, archivierter Versuch |
| kein eigener Worktree | `turbo-c6-penny-ssd-experimental`, unveroeffentlichter Altbranch wird erhalten |
| `qwen38-flash-next-sm120` | `copilot-sm120`, neuer Source-Fork, privates eigenes Remote |
| `qwen38-flash-next-blackwell` | `main`, alter Runner, kein Autostart |
| `workstation-setup`, `cachyos-kvm-lab`, `hermes-team-workspace` | jeweiliges `main`, inklusive bisher ungepushter Arbeit |
| `research/sglang`, `research/sglang-flashnext-sm120`, `research/sglang-rtxpro6000` | saubere, gepinnte Upstream-Referenzen |

Auch `llm-infra-setup/main` und vorhandene Tags bleiben erhalten. Der Default-
Branch auf GitHub muss nicht der gewuenschte Arbeitsbranch sein:

```bash
mkdir -p ~/work
cd ~/work
git clone --branch turbo-c6-production https://github.com/thomasdenk79-cyber/llm-infra-setup.git
git -C llm-infra-setup worktree add ../llm-infra-setup-pennyroyal pennyroyal-plugin-variant
git clone --branch copilot-sm120 https://github.com/thomasdenk79-cyber/qwen38-flash-next-sm120.git
```

Private Repositories brauchen vorher `gh auth login` oder passende SSH-
Authentifizierung. Alte `.git`-Worktree-Pointer nicht blind von einem anderen
Pfad kopieren; Worktrees frisch mit `git worktree add` anlegen.

## Was wirklich lief

Die Aufnahme in `migration/20261006/inventory.json` enthaelt 16 laufende
Container, vier Podman-Netzwerke, keine benannten Volumes und keine echten
Podman-Pod-Gruppen. Die Dienste sind einzelne rootless Quadlet-Container;
der umgangssprachliche Begriff "Pods" meint hier den gesamten Stack.
Alle Mounts, Image-IDs/Digests, Portbindungen, ENV-Namen und nicht geheimen
Runtime-Stellwerte stehen im Inventar. Keine ENV-Geheimniswerte wurden exportiert.

| Dienstgruppe | Quelle im Snapshot |
|---|---|
| Pennyroyal / LiteLLM / PostgreSQL / Open WebUI | `quadlet/` und `env-examples/` |
| Prometheus / Grafana / Loki / Alloy / Dozzle / Homepage / Exporter | `quadlet/`, `homepage/`; Monitoring-Konfigs im Repo |
| Reverse-SSH-Tunnel | `quadlet/llm-autossh.container`, `env-examples/`; Schluessel nur lokal |
| LAN-HTTPS und Root/Subpath-Routing | `nginx/`, inkl. historischer Konfig-Backups; TLS-Keys nur lokal |
| Fakten-Timer / Hermes / Kontext-Watchdog / Runner-Supervisor | `user-systemd/`, nur archiviert, nicht automatisch aktivieren |
| Alte Turbo-Varianten | separate `sglang-turbo-*.container`, ausdruecklich keine gemeinsame Deployment-Liste |

Die drei zufaellig benannten Node-Exporter (`infallible_aryabhata`,
`funny_colden`, `nifty_swanson`) liefen ebenfalls. Sie werden als Altbestand
dokumentiert und nicht geloescht; fuer den Zielaufbau den verwalteten
`llm-node-exporter` verwenden, nicht die Duplikate automatisch wieder starten.

Wichtig: Installierte Quadlets und laufende Container koennen verschiedene
Worktree-Pfade referenzieren (z.B. Grafana). Der Snapshot archiviert die
installierten Dateien **und** die tatsaechlichen Container-Mounts. Er
ueberschreibt keine Generatoren und wendet keine Unit-Aenderung live an.
Vor dem Deployment Quellpfade und Generatoren bewusst abgleichen.

Die Referenz war `pennyroyal.service` aktiv, Health 200, exklusiver Modell-
Container. Profil: Kontext 524288/YaRN2, FP8-KV, online MXFP8, HiCache 16
dezimal GB, NVMe-PLE, MR6/Mamba36/Graph6, mem_fraction 0.981, NEXTN 3/1/4,
kein Sleep/Memory-Saver. Angefordert 1048576 KV-Tokens, tatsaechlicher Pool
1041472. Der neue Fork ist **nicht** als Produktion/LKG promoviert.

Der alte Supervisor war noch aktiv, aber `state/STOP` im Runner-Repo blockierte
den Queue-Neustart. Auf dem Ziel **keinen** Runner, Supervisor oder Watchdog
aktivieren. Cloud-Copilot und der Foreground-Controller im Source-Fork ersetzen
diesen alten lokalen Agenten-Resume-Ablauf. Hermes ist optional und seine
extern installierte Agent-Software kein Teil dieses Git-Repositories.

## Lokales vertrauliches ZIP

Der Betreiber erhaelt `/home/z000g9hu/migration-20261006.zip` und die zugehoerige
SHA256-Datei. `howto.md` im ZIP beschreibt Inhalt, Pruefung und Rueckgabe.
Die Datei ist **nicht verschluesselt**, aber lokal mit Rechten **0600**
geschuetzt; nur via SSH/SFTP uebertragen, nicht in Git/Cloud-Uploads legen.
Der Dateischutz ersetzt keine Verschluesselung nach dem Kopieren auf Windows.

Enthalten sind die notwendigen lokalen ENV-/Secret-Dateien, Podman-Secret,
gezielt benoetigter Tunnel-Schluessel, TLS-Dateien soweit lesbar, Konfigurationen,
ignorierte Versuchsevidenz und private Anwendungssicherungen. Die abschliessende
Inhaltsliste und Pruefsummen im ZIP sind massgeblich. Secrets koennen alternativ
neu erzeugt werden; dann muessen Gateway, Clients, Datenbank, Grafana und
Open WebUI zusammenpassende Werte erhalten. Historische Tokens sind kein
Grund, sie weiterzuverwenden.

**Nicht durch Git oder dieses kompakte ZIP ersetzt:**

- Modell-Shards unter `/srv/llm/models/` und vorbereitete PLE-Daten unter
  `/srv/llm/ple-native/` separat kopieren oder reproduzierbar neu aufbauen.
- Container-Layer und Compiler-/NIXL-/Hugging-Face-Caches sind keine
  Quellkonfiguration. Pinned Images pullen, Fork-Overlay neu bauen.
- VM-Disks/ISOs, allgemeines Home-Verzeichnis, Desktop-Keyring sowie Windows-
  oder Firmenanmeldungen werden nicht pauschal kopiert.
- Bei laufenden Diensten sind SQLite-Online-Backups/`pg_dump` konsistent,
  sonstige Dateikopien nur eine Bestandsaufnahme, kein atomarer Host-Snapshot.

## WSL-Aufbau in sicherer Reihenfolge

1. Windows-/WSL-Version, Ziel-GPU, Compute Capability, VRAM, RAM, Swap,
   Datentraeger und freien Platz erfassen. Die bisherige GPU ist eine RTX PRO
   6000 Blackwell mit 96 GiB VRAM. Ob sie am P16/unter WSL nutzbar ist, ist
   ungeprueft. Bei anderer Hardware nicht den SM120/96-GiB-Start erzwingen.
2. WSL2 mit Linux-nativem Dateisystem benutzen. Repositories/Modelle/PLE nicht
   auf `/mnt/c` als vermeintlich gleichwertigem Performancepfad betreiben.
   WSL-RAM/Swap-Limit auf den Zielhost abstimmen, nicht alte Werte blind kopieren.
3. NVIDIA-Unterstuetzung kommt vom Windows-Treiber. Keine Linux-Kernel-Treiber,
   DKMS, Arch-Pakete, GRUB-, ZFS-Pool-, udev- oder Thunderbolt-Power-Skripte
   blind aus diesem CachyOS-Repo ausfuehren. **`./setup.sh` ist kein WSL-Installer.**
4. systemd/rootless Podman/NVIDIA-Container-Unterstuetzung gezielt einrichten
   und nachweisen. Quell-UID 1000, Home-Pfade, `/srv`-Mounts, SELinux-Optionen,
   `/dev/nvidia*`-Annahmen und CDI-Erzeugung sind nicht automatisch portabel.
   Netzwerk/Windows-Firewall und Bind-Adresse neu festlegen.
5. Repos und gewuenschte Worktrees klonen, Secrets privat wiederherstellen
   oder neu erzeugen. Zunaechst nur nicht-GPU-Dienste einrichten. Die alten
   `192.168.0.198`-URLs und Zertifikate sind keine Zielkonfiguration.
6. Modelldaten und PLE gezielt per SSH/rsync mit Metadaten kopieren; danach
   Shard-/Manifest-/Pruefsummenabgleich. Nicht formatieren und nicht in fremde
   Datenbestaende schreiben. PLE bleibt gepuffertes Filesystem-I/O, kein O_DIRECT.
7. Persistente Dienstdaten bzw. DB-Backups zurueckgeben, Berechtigungen auf
   Ziel-UID/Container-IDs abbilden. Erst dann bewusst gewaehlte Units starten.
   `:U` kann grosse Verzeichnisse rekursiv umschreiben; nicht blind einsetzen.
8. Referenz allein starten, Health 200, tatsaechlichen KV-Pool, Reserve und
   Modellqualitaet messen. Ein schnellerer Host garantiert keine GPU-Paritaet.
   Erst danach Source-Fork bauen und einen freigegebenen sequenziellen
   Test/Restore-Lauf ausfuehren. Keine automatischen alten Fallback-Tasks.

## Vorhandene Dirty-Arbeit: erhalten, nicht schoengeschrieben

Der alte Power-Stability-Fix deaktiviert hostweit Runtime-PM und aendert GRUB;
er ist hardwaregebundene Bestandsarbeit, keine WSL-Freigabe. Ebenso bleiben
die vorgefundenen LAN-URLs, 60s-Prometheus-Intervalle, Dozzle-Subpath und
Variant-B-Schalter erhalten. Diese Sicherung ist keine nachtraegliche
Produktionszertifizierung alter Experimente. `make drift` kann Generatoren
ausfuehren und Dateien veraendern; nicht fuer eine reine Sicherung blind
aufrufen. Keine Runtime wurde fuer diese Migration neu gestartet.
