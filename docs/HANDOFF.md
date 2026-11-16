Zuletzt gesichert: 2026-10-11T15:08:46+02:00 durch `scripts/session-checkpoint.sh`

# Arbeitsstand und Uebergabe (2026-11-16)

**Diese Seite ist der Fortsetzungsanker.** Wenn eine Sitzung abreisst, der
Rechner neu startet oder ein anderer Agent uebernimmt: hier steht, was gilt.
Regel aus `AGENTS.md`: Nach jedem abgeschlossenen Schritt
`./scripts/session-checkpoint.sh` (aktualisiert diese Seite, committet, pusht).
Das Repository ist das Backup.

## 1. Was gilt jetzt (2026-11-16)

* Repo-Wurzel ist `/srv/work/llm-infra-setup` (nicht mehr `~/work/...`).
  Die Arbeiten des Tages sind in Themen-Commits gesichert (`git log --oneline -8`);
  der Fortschritt liegt damit in Git und ist nicht nur lokal vorhanden.
* Inferenz-Laufzeit ist der unmanaged Container `flash-next-v3` (vLLM) mit
  API nur auf `127.0.0.1:30000`. Es gibt auf diesem Rechner KEIN Pennyroyal;
  `config/host.env` (`RUNTIME_CONTAINER=flash-next-v3`, `RUNTIME_UNIT=` leer,
  `RUNTIME_PORT=30000`) ist die kanonische Ansprache fuer Pruefskripte.
  Metriken stellt die Repo-Unit `llm-vllm-forwarder.service` auf Port 30001
  bereit (`scripts/73-setup-vllm-forwarder.sh`); sie bindet Loopback und die
  Host-Adressen, weil rootless pasta die Host-Loopback nicht an Container
  durchreicht (`docs/runtime.md`). Die auswaertige `luni-vllm-pub.service` ist
  retired: `~/.config/systemd/user/luni-vllm-pub.service.retired-20261116`.
* Gateway: `litellm` v1.105.0, nur `127.0.0.1:4000`, 13 Modelle in
  `config/litellm.yaml`. `chatgpt/gpt-6-luna` ist ausgelassen: Das Token unter
  `~/.config/llm-infra/chatgpt-tokens/auth.json` ist eine reine Merkdatei
  (nur `device_code_requested_at`), der ungebundene OpenAI-Device-Code-Flow
  verhinderte sonst die Bindung von :4000. Faellkette laeuft als zwei Stufen
  `qwen3.8-flash-next -> bonsai-2-27b`.
* Oeffentlicher Zugang der Kollegen: ausschliesslich Port 443 des
  Azure-Gateways `edipoc-gateway.westeurope.cloudapp.azure.com` (20.73.54.102)
  ueber die verwaltete `llm-reverse-tunnel.service` + Caddy auf der VM.
  Gemessen: `/health/liveliness` 200, `/v1/models` 401, `/` 401, `/grafana/`
  401 (DNS wie Roh-IP). Basic-Auth-Personen: owner, thomas, martin, johannes,
  holger. Persoenliche Gateway-Schluessel: `scripts/71-gateway-keys.sh`.
  Die alte unverwaltete `reverse-tunnel.service` ist gestoppt, deaktiviert und
  liegt wiederherstellbar unter
  `~/.config/systemd/user/reverse-tunnel.service.retired-20261116`.
  Doku: `docs/gateway-proxy.md`.
* Beobachtung: Alertmanager laeuft (127.0.0.1:9093), Prometheus meldet ihm
  die Regeln, Versandkanal bewusst noch zu. Alloy sammelt jetzt auch
  `flash-next-v3` ueber das Journal (`/var/log/journal` read-only, Alloy
  lauscht auf `0.0.0.0:12345`). Alle Alarmregeln und Dashboards sind von
  `sglang:*` auf die vorhandenen `vllm:*`-Messgroessen umgelenkt;
  Dashboard-Check 2026-11-16: 104 OK / 12 leer / 0 Fehler (die 12: ZFS/PLE,
  dieser Rechner hat beides nicht). Grafana haengt wegen des oeffentlichen
  Unterpfads an `~/.config/llm-infra/grafana.env`
  (`GF_SERVER_ROOT_URL=.../grafana/`, `GF_SERVER_SERVE_FROM_SUB_PATH=true`).
* Wiki: `wiki.service` liefert `http://127.0.0.1:3003/` (200),
  `wiki-rebuild.timer` laeuft alle 30 Minuten, `site/.built-sha` gleicht HEAD.
* Verifizierter Einzelzustand mit den Beweis-Befehlen: `docs/status.md`.

## 2. Was ist offen

1. Nach jeder Aenderung sichern: `./scripts/session-checkpoint.sh "kurze Notiz"`
   (AGENTS Grundregel 0; prueft, committet, pushed).
2. Alarmkanal waehlen und eintragen: `docs/monitoring.md#alarmkanal`
   (ntfy ohne Konto oder SMTP; danach `systemctl --user restart alertmanager.service`).
3. Oeffentliche Browser-Pruefung des Grafana-Zugangs steht aus: dafuer braucht
   es ein Basic-Auth-Passwort. `team-users.txt` enthaelt nur bcrypt-Hashes, die
   Klartexte kennt nur der Betreiber. HTTP-seitig ist die Kette gemessen
   (401 ohne Zugang, 200 auf `/health/liveliness`, Tunnel-Forward 4000/3000/3002).
4. Falls Luna gewollt ist: Geraetelogin durchfuehren (echtes Token unter
   `~/.config/llm-infra/chatgpt-tokens`), danach `./scripts/60-install-gateway.sh`
   erneut ausfuehren.
5. Altbestand in den Docs, ausserhalb der heutigen Sechserliste: `README.md`
   (zeigt Pennyroyal auf 8001, Pfad `~/work/llm-infra-setup`),
   `docs/install.md` (alter Pfad), `docs/troubleshooting.md` und
   `docs/performance.md` (sglang-Formulierungen), `AGENTS.md` Zweckzeile
   (Pennyroyal/SGLang). Nachziehen in einer eigenen Runde.
6. Start-Gate der Referenz-Runtime: die Zeile war ein Uberbleibsel aus einer
   Generator-Fassung und ist entfernt (Drift ist damit gruen). Falls ein Referenz-
   Rechner das Gate wirklich braucht, es in `scripts/50-install-pennyroyal.sh`
   wieder erzeugen lassen - nicht in der Quadlet-Datei.
7. Waechter- und GitOps-Timer (`llm-runtime-watchdog`, `llm-litellm-watchdog`,
   `llm-crashguard`, `llm-infra-gitops`) sind auf diesem Rechner nicht
   installiert; bei Bedarf ueber die `--install`-Pfade der jeweiligen Skripte.

## 3. Welche Befehle braucht der naechste Leser

```bash
cd /srv/work/llm-infra-setup

# Lagebild
./scripts/doctor.sh                                  # nennt zu jedem Punkt den naechsten Befehl
./scripts/healthcheck.sh
./scripts/session-checkpoint.sh --status

# oeffentlicher Zugang
./scripts/70-setup-gateway-proxy.sh --check
./scripts/70-setup-gateway-proxy.sh --status
./scripts/71-gateway-keys.sh --list

# Beobachtung
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:9093/-/ready
curl -s 'http://127.0.0.1:9090/api/v1/targets' | python3 -c 'import json,sys;[print(t["labels"]["job"],t["health"]) for t in json.load(sys.stdin)["data"]["activeTargets"]]'
./scripts/60-install-monitoring.sh --check

# Laufzeit und Gateway
podman ps --filter name=flash-next-v3
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:30000/health
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:4000/health/liveliness
```

## 4. Historische Notizen (unveraendert uebernommen)

Die Mikronotizen 2026-10-02 bis 2026-10-09 (Tuning-Runden, Profile,
Messprotokolle der WSL-Zeit) sind unveraendert im Git-Verlauf:
`git show HEAD:docs/HANDOFF.md`. Hier steht noch der komplette Uebergabeblock
vor der CachyOS-Neuinstallation, weil seine Fakten (Modell-Backup auf externer
SSD, Speicherbefund) ausserhalb des Git-Verlaufs sonst nirgends stehen.

### Handover vor CachyOS-Neuinstallation (2026-10-11)

Die laufende Infrastruktur wurde vor der Neuinstallation angehalten:
`systemctl --user stop pennyroyal.service`. LiteLLM-/Hermes-Konfiguration,
Gateway-Fallback und die lokalen Änderungen liegen im Git-Repository.

#### Bewiesenes Routing

Hermes ist auf `qwen3.8-flash-next` ueber `http://127.0.0.1:4000/v1`
konfiguriert. Als Pennyroyal zuvor nicht startete, lieferte eine direkte
LiteLLM-Anfrage mit diesem Alias `model: gpt-6-luna`; Ursache war die bewusst
konfigurierte Kette `qwen3.8-flash-next -> bonsai-2-27b -> gpt-6-luna`.
Nach erfolgreichem Pennyroyal-Start lief dieselbe Probe ueber LiteLLM mit
`model: qwen3.8-flash-next`.

#### Speicherbefund und offene Korrektur

Der Rechner hat 197,5 GB RAM (188 GiB). Der fruehere Startfehler war
Host-RAM, nicht VRAM:

```text
ValueError: Not enough host memory available. Requesting 26.56 GB but only have 25.34 GB free. Please reduce the size of the hierarchical cache.
```

Das war kein cgroup-Limit (`MemoryMax=infinity`). Beim Ladepeak lagen laut
systemd 133,5 GB Prozess-RAM und 1,1 GB Swap-Peak an; die RAM-PLE-Konfiguration
und der Modell-Lader liessen in diesem Moment nur 25,34 GB fuer den HiCache
uebrig. `free` zeigte spaeter 197,5 GB total, 67,4 GB `MemAvailable`, davon
10,8 GB wirklich frei und 81,2 GB Page Cache. Linux-Cache ist reclaimable,
aber SGLang prueft den akut freien Host-Pool und reserviert nicht einfach
gegen den gesamten theoretisch freien RAM.

Die zwischenzeitlich erfolgreiche Konfiguration lief mit `HiCache: 8 GB` und
`PENNY_PLE_BACKEND=ram`. Sie startete und erreichte fuer C1 gute Decode-Werte
bis etwa 225 Token/s. Fuer die urspruenglich gewuenschte Kombination
`HiCache=32 GB` muss die alte SSD-PLE-Strecke wiederhergestellt werden; die
SSD-PLE-Datei war auf dem Rechner noch nicht vorbereitet. Der erste Versuch,
das Overlay zu bauen, scheiterte nur an einem Namens-Mismatch:

```text
prepare_ple_nvme: [Errno 2] No such file or directory: '/models/Qwen3.8-Flash-Next-NVFP4'
```

Das vorhandene Modell heisst im aktiven `/srv`-Layout
`RadixArk-Qwen3.8-Flash-Next-NVFP4`. `scripts/48-prepare-ple-nvme.sh` hat jetzt
dafuer `PENNY_PLE_SOURCE_DIR` als explizite Quelle.

#### Letzter Lauf: erfolgreich, dann spaeterer GPU-Abbruch

Der Server war nach dem Start gesund und beantwortete `/health`. Ein C1-Lauf
zeigte unter anderem:

```text
Decode batch, #running-req: 1, #full token: 143488, accept len: 2.38,
accept rate: 0.46, cuda graph: True, gen throughput (token/s): 225.08
Decode batch, #running-req: 1, #full token: 144320, accept len: 2.20,
accept rate: 0.40, cuda graph: True, gen throughput (token/s): 209.72
```

Der spaetere Abbruch am 14:16:56 war ein anderer Fehler als der Startup-RAM-
Fehler. Der relevante Stacktrace:

```text
Scheduler hit an exception
  scheduler.event_loop_overlap()
  scheduler.get_next_batch_to_run()
  scheduler.get_new_batch_prefill()
  flatten_arrays_to_pinned_cpu(input_ids, _pin)
  cpu_t.pin_memory()
torch.AcceleratorError: CUDA error: unspecified launch failure
Search for `cudaErrorLaunchFailure'
For debugging consider passing CUDA_LAUNCH_BLOCKING=1
```

Unmittelbar davor liefen Mamba-Reclaim/Match-Meldungen (`mamba_used=17`,
`mamba_total=17`). Der Prozess beendete sich danach mit SIGQUIT; systemd
meldete 109,5 GB Speicher-Peak und nur 112 KB Swap-Peak. Dieser Fehler ist
VRAM-/CUDA-/asynchroner Kernel-Kontext und muss getrennt vom Host-HiCache-
Problem untersucht werden. Fuer die naechste Sitzung zuerst reproduzieren mit
`CUDA_LAUNCH_BLOCKING=1`, dann C1 ohne lange Prefill-Fortsetzung und mit
SSD-PLE vergleichen.

#### Aktueller Stand / naechste Schritte (Stand 2026-10-11, historisch)

* Pennyroyal ist gestoppt; kein weiterer Analyse- oder Neustartlauf wurde
  gestartet.
* Repo-Defaults wurden auf `PENNY_HICACHE_SIZE_GB=8` gesetzt, damit der
  RAM-PLE-Start robust bleibt; der aktive alte Startscript-Stand liegt unter
  `/srv/ai/pennyroyal/config/config/` und wurde ebenfalls auf 8 gesetzt.
* Fuer SSD-PLE zuerst Overlay korrekt erzeugen, z.B. mit
  `PENNY_PLE_SOURCE_DIR=/srv/ai/models/RadixArk-Qwen3.8-Flash-Next-NVFP4`
  und einem passenden `PENNY_PLE_NVME_MODEL` unter `/srv/ai/pennyroyal/ple`.
  Danach aktive Unit auf `PENNY_PLE_BACKEND=nvme`, `/ple`-Mount und 32-GB-
  HiCache umstellen und erst dann neu starten.
* Die CachyOS-/WSL-/GPU-Konfiguration, das vorhandene Modell unter `/srv/ai`
  und die lokalen Secrets vor der Neuinstallation extern sichern.

#### Lokales Modell-Backup auf externer SSD

Das vollständige Modell `RadixArk-Qwen3.8-Flash-Next-NVFP4` ist bereits auf
der externen SSD vorhanden:

```text
Quelle: /srv/ai/models/RadixArk-Qwen3.8-Flash-Next-NVFP4
Backup: /run/media/z000g9hu/DATA_NTFS/HF-models/RadixArk-Qwen3.8-Flash-Next-NVFP4
```

Die SSD ist `/dev/sda3` (NTFS, Label `DATA_NTFS`) und wurde mit `ntfs3,force`
gemountet. Ein `rsync --dry-run` meldete danach 682 Quelldateien, 682
Backup-Dateien und `Number of regular files transferred: 0`; das Backup ist
damit strukturell vollständig. Die Größenanzeige von NTFS (`319G`) kann von
der logischen Modellgröße (`341.621.827.210` Bytes, etwa 281 GiB) abweichen.
Fortsetzen/erneut prüfen:

```bash
rsync -a --human-readable --info=progress2 --partial \
  /srv/ai/models/RadixArk-Qwen3.8-Flash-Next-NVFP4/ \
  /run/media/z000g9hu/DATA_NTFS/HF-models/RadixArk-Qwen3.8-Flash-Next-NVFP4/
```

Andere Agenten sollen vor einem erneuten Hugging-Face-Download zuerst diesen
lokalen Backup-Pfad prüfen. Ein späterer Restore kann per `rsync` zurück nach
`/srv/ai/models/` erfolgen.

## Naechste Befehle

```bash
cd /srv/work/llm-infra-setup
./scripts/doctor.sh                                   # Lagebild, nennt den naechsten Befehl
./scripts/session-checkpoint.sh --status              # ungesicherte Aenderungen zeigen
./scripts/session-checkpoint.sh "Doku-Stand 2026-11-16"   # sichern (kommender Schritt des Betreibers)
```
