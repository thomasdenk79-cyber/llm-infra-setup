Zuletzt gesichert: 2026-11-16T14:28:31+01:00 durch `scripts/session-checkpoint.sh`

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
* Lokaler HTTPS-Zugang ueber Namen (2026-11-16, neuer Rund): Container
  `llm-proxy` (Caddy, Netz `llm-observability`, nur `127.0.0.1:443`) bedient
  `https://homepage.localhost/` (Portal) und `https://grafana.localhost/grafana/`
  (Grafana ohne Anmeldung, Unterpfad bleibt). Generator
  `scripts/74-setup-local-proxy.sh` (`make local-proxy`, `--check`,
  `--ca-import`, `--render` fuer `make drift`), Vorlage
  `config/proxy/Caddyfile.template`, Quadlet `quadlet/llm-proxy.container`.
  Caddy-CA im Systemtrust verankert; Kernelgrenze
  `net.ipv4.ip_unprivileged_port_start=443` ueber
  `/etc/sysctl.d/99-llm-infra-local-proxy.conf` (sudo, reversibel).
  Grafana anonym+einbettbar via `~/.config/llm-infra/grafana.env` (Generator
  `scripts/60-install-monitoring.sh`); dazu entfiel die
  `Environment=GF_AUTH_ANONYMOUS_ENABLED=false`-Zeile in
  `quadlet/grafana.container` (podman: `--env` schlaegt `--env-file`).
  Gemessen: beide Namen 200 ohne `-k`, `d-solo?panelId=2` 200 ohne Cookies
  (alle fuenf Dashboards), oeffentlich weiterhin `/grafana/` 401 und
  `/v1/models` 401. Doku: `docs/operations.md`, `docs/status.md`.
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
* Portal: `homepage.service` laeuft auf dem in `versions.lock` gepinnten
  Digest `ghcr.io/gethomepage/homepage@sha256:3e38fe78…` (Tag v2.6.0) -
  gemessen 2026-11-16: `--check` rc=0, `https://homepage.localhost/` 200,
  alle 16 `/icons/<datei>` 200, Playwright-Netzliste 0 externe Anfragen
  (kein `cdn.jsdelivr.net`). Erst 2.6.0 kennt Tabs: die sechs Gruppen aus
  `config/homepage/settings.yaml` (Dashboard, LLM, INFRA, SYSTEM, BETRIEB,
  TOOLS) sind gemessen klickbar (Screens `/tmp/qa/screens/portal-260-*.png`).
  Der Installer rollt die Unit jetzt ueber `lib/units.sh` aus; vorher
  installierte `scripts/60-install-homepage.sh` die Unit nie nach
  `~/.config/containers/systemd`, der Live-Container hing dadurch auf
  v2.4.0 fest. Beweise: `CHANGELOG.md`, `docs/status.md`.
* Verifizierter Einzelzustand mit den Beweis-Befehlen: `docs/status.md`.

## 2. Was ist offen

- **Laufzeit ohne Unit (wichtigster offener Punkt):** der Inferenz-Container
  `flash-next-v3` (Bild `localhost/qwen38-fp4-tp1:v3`, 11 h Laufzeit) wird von keiner
  Unit und keiner Quadlet-Datei verwaltet - weder auf Benutzer- noch auf Systemebene,
  auch nicht ueber einen Pod. Nach einem Neustart des Rechners kommt das Modell nicht
  zurueck, und `make drift` laeuft an `quadlet/pennyroyal.container` ins Leere, weil
  dort eine andere Laufzeit beschrieben steht (Fork `localhost/flash-next-sm120:serving`).
  Entscheidung des Betreibers erforderlich: Unit einrichten (erzwingt einen
  Laufzeit-Neustart von rund 15 Minuten, abbruch bei laufenden Anfragen) oder bewusst
  manuell lassen. Nichts davon ist ohne diese Antwort geschehen.
- **Anleitung wieder bedient (2026-11-16, gemessen):** die TOOLS-Kachel zeigte auf
  `https://homepage.localhost/anleitung/`, ohne dass jemand die Seite auslieferte.
  Sie liegt jetzt als `config/proxy/site/anleitung/index.html` im Repo, haelt den
  Windows-Schnellstart aus dem alten Bestand (`luni-llmops-linux`, Zweig
  `fix/homepage-local-recovery`) und den Betriebsteil, und wird von Caddy unter
  `/anleitung/` bedient. Gemessen: `200`, Kachelklick oeffnet `_blank` mit `200`.
- **`check-drift.sh` aendert den Baum nicht mehr (2026-11-16, gemessen):** die Pruefung
  liess die Generatoren im Arbeitsverzeichnis laufen und verglich dann mit `git diff`
  - derselbe Eingriff, den sie melden soll. Nach jedem `make drift` lag eine
  geaenderte `quadlet/pennyroyal.container` im Baum, und ein `git add` darauf haette
  unbeaufsichtigt die Generatorfassung unterschrieben. Genau das ist passiert: Commit
  `88a95c8` brachte das Upstream-Bild `ghcr.io/jpezzulli/sglang-rtxpro6000:v2.5.3`
  statt der Fork-Fassung des Betreibers ins Repo; zurueckgenommen in `093e2bf`
  (Stand `e9085c6`). Heute laufen die Generatoren in einer weggeworfenen
  `git worktree`-Kopfe, und die Drift-Kapsel in `lib/units.sh` (`LLM_DRIFT=1`)
  verhindert Installation, `daemon-reload` und Starts - auch bei Generatoren, die
  `systemctl` direkt aufrufen. Gemessen nach dem Umbau: `make drift` schlaegt weiter
  rot an fuer die bekannte Pennyroyal-Abweichung, das Arbeitsverzeichnis bleibt
  unbearbeitet, Unit-Verzeichnis und Container unveraendert. `--restore` ist
  weggefallen (nichts mehr zurueckzuholen).

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
6. `make drift` ist nicht gruen, und der Grund ist grosser als zuerst angenommen:
   `quadlet/pennyroyal.container` (Referenzrechner, Bild `localhost/flash-next-sm120:serving`,
   `Ulimit`-Deckel, Start-Gate) weicht in mehreren Feldern von dem ab, was
   `scripts/50-install-pennyroyal.sh` schreibt (pinned `sglang-rtxpro6000:v2.5.3`, keine
   Deckel, Modellpfad `/srv/llm-models`). Entscheidung noetig, welche Fassung die
   Referenz ist; dann Generator nachziehen, nicht die Datei. Die Unit laeuft hier nicht.
   (Die fruehere Annahme, es sei nur die Gate-Zeile, war falsch und ist zurueckgenommen.)
7. Chat-Oberflaeche Open WebUI (Port 127.0.0.1:3001): es gibt noch kein Konto - das
   erste Konto wird Administrator. `credentials.txt` sagt bisher "beim ersten Start ein
   eigenes Konto anlegen" Dafuer liegt `scripts/64-setup-open-webui-account.sh`
   (erzeugt Zugangswert, schreibt ihn in `credentials.txt` 0600, prueft die Anmeldung,
   idempotent, keine Ausgabe des Werts). Nach dem Anlegen haingt die Playwright-Pruefung
   der Chat-Antwort noch fest. Anbieter und Grundadresse sind richtig
   (`quadlet/open-webui.container`, Datenvolumen haelt unter `~/.local/share/llm-infra/open-webui`).
8. Waechter- und GitOps-Timer (`llm-runtime-watchdog`, `llm-litellm-watchdog`,
   `llm-crashguard`, `llm-infra-gitops`) sind auf diesem Rechner nicht
   installiert; bei Bedarf ueber die `--install`-Pfade der jeweiligen Skripte.

15. **Erledigt 2026-11-16: Portal-Symbole und Tabs laufen lokal.** Das Portal
    laeuft digest-pinnt auf v2.6.0 (`versions.lock`), die sechs Tabs aus
    `config/homepage/settings.yaml` sind gemessen klickbar, und die Symbole
    liegen versioniert unter `config/homepage/icons/` und werden dateiweise
    read-only nach `/app/public/icons/` eingebunden: alle 16 Dateien
    liefern 200, die Playwright-Netzliste zaehlt 0 Anfragen an
    `cdn.jsdelivr.net` oder andere externe Hosts. Der fruehere Stand dieser
    Nummer (v2.4.0 ohne lokale Symbolaufloesung, tote PNGs unter
    `config/homepage/public/icons/`) ist damit gegenstandslos; Beweise in
    `CHANGELOG.md`, `docs/status.md` und `/tmp/qa/playwright-network.json`.
    Naechster Befehl: `./scripts/60-install-homepage.sh --check`.
16. **Grafana-Wurzeladresse ist jetzt der lokale Name.** Eine Instanz kann nur
    eine `GF_SERVER_ROOT_URL` haben; sie zeigt auf
    `https://grafana.localhost/grafana/` (Betreiberauftrag: lokaler Zugang ohne
    301 auf Azure). Der oeffentliche Zugang bleibt durch Basic-Auth geschuetzt
    (gemessen 401 auf `/grafana/` und `/v1/models`), aber absolute Links der
    ausgelieferten Seiten zeigen auf `grafana.localhost` - fuer Eingeloggte ausserhalb
    des Rechners brachen damit Assets. Optionen: Gateway-Caddy eine zweite
    `grafana.localhost`-Site geben und Einwahl-Rechnern eine Hosts-Zuordnung
    mitgeben, oder eine zweite Grafana-Instanz fuer den oeffentlichen Weg. Naechster
    Befehl: mit einem Zugangsschluessel
    `curl -u person https://edipoc-gateway.westeurope.cloudapp.azure.com/grafana/`
    ziehen und die Link-Ziele im HTML zaehlen, bevor entschieden wird.
17. **`make drift` wartet auf den Commit dieser Runde.** Die neue Datei
    `quadlet/llm-proxy.container` und die geaenderten
    `quadlet/homepage.container`/`quadlet/grafana.container` sind bewusst
    nicht committet (Betreiberauftrag: nichts committen). Die
    Drift-Pruefung weist ungecommittete generierte Dateien zurueck; vor der
    Runde war sie auf dem Stand "nur die bekannte Pennyroyal-Abweichung".
    Naechster Befehl: nach `git add ... && git commit` erneut `make drift`
    (erwartet: wieder nur Pennyroyal).

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
./scripts/74-setup-local-proxy.sh --check             # lokaler HTTPS-Zugang ueber Namen?
./scripts/60-install-homepage.sh --check              # Portal: Bild, Unit, Symbole, Antworten?
./scripts/session-checkpoint.sh --status              # ungesicherte Aenderungen zeigen
./scripts/session-checkpoint.sh "Doku-Stand 2026-11-16"   # sichern (kommender Schritt des Betreibers)
```

## Notiz 2026-11-16T13:07:21+01:00

portal+proxy: benanntes HTTPS (homepage/grafana.localhost), Grafana anonym und einbettbar, Kachelsonden

## Notiz 2026-11-16T13:45 (Portal-Umstellung abgeschlossen)

`scripts/60-install-homepage.sh` rollt die Quadlet-Unit jetzt ueber
`lib/units.sh` aus (install_units + systemd_reload, Start/Restart nur bei
Abweichung); der --check prueft seiteneffektfrei und ueberlebt den
frueheren SIGPIPE-Bildvergleich. Portal laeuft auf dem gepinnten
2.6.0-Digest, Tabs klickbar, alle Symbole lokal, 0 externe Anfragen.
Bericht: `/tmp/qa/homepage-install-bericht.md`. Nichts committet
(Betreiberauftrag); `make drift` wartet weiter auf den Commit (Punkt 17).

## Notiz 2026-11-16T13:42:46+01:00

portal: 2.6.0 mit Tabs, lokale Symbole statt CDN, Proxy-Kennzahlen und Diagnosefall

## Notiz 2026-11-16T14:25:22+01:00

Diagnosefall Laufzeit-Unit, Dashboard ohne No-Data-Panels, eigener Chat-Schluessel

## Notiz 2026-11-16T14:28:31+01:00

chat: eigener Gateway-Schluessel, Dashboard ohne No-Data, Diagnosefall Laufzeit-Unit
