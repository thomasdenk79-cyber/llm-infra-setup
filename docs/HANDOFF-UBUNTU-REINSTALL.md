# Uebergabe: OS-Neuinstallation auf Ubuntu (geplant 2026-10)

Ausgangspunkt: CachyOS/Arch (rolling) -> Ziel: **Ubuntu LTS 24.04 (Noble)**, dieselbe
Hardware. Gesamter Inhalt von `/srv` wird geloescht. Dieses Dokument plus
`scripts/reinstall-preserve.sh` sind der komplette Wiederanlaufplan.

## Hardware (fest, nicht veraendert)

* GPU 1: NVIDIA RTX PRO 6000 Blackwell, UUID
  `GPU-780d3589-9811-40ec-db66-93a9146697f3`, SM120, 97.887 MiB, Treiber 610.57.04
* GPU 0: RTX 3500 Ada (Bonsai-Zukunftsplatz, CUDA_VISIBLE_DEVICES=0 fuer Bonsai)
* Disks: nvme0n1 (3,6T KINGSTON SFYRD4000G; p3/p5 = Windows/BitLocker, nicht anfassen),
  nvme1n1 (3,6T KINGSTON SFYRD4000G: p1 /boot vfat, p2 208G + p3 3,4T = ZFS-Mitglieder)
* Extern: sda (3,7T XS2000) — sda1 exfat „Ventoy" (200G), sda3 NTFS „DATA_NTFS" (3,3T,
  haengt derzeit unclean; ggf. `ntfsfix` von einem Linux- Livesystem)
* Hostname bisher: cachyos-x8664, User z000g9hu (uid 1000)

## Was existiert und erhalten werden MUSS

| Pfad | Inhalt | Weg nach Ubuntu |
|---|---|---|
| ~/work/llm-infra-setup | Repo this; Setup-Skripte | Git-Bundle -> git clone (Remote: thomasdenk79-cyber/llm-infra-setup) |
| /srv/github/pennyroyal | Fork jpezzulli/sglang-rtxpro6000, Branch hermes/pennyroyal-local-dev; lokaler Build-Tag john-repair-5d33142c1 | Bundle; Image neu bauen (Containerfile im Branch john/pennyroyal-container-v3.0-repair, Commit 5d33142c1) oder vorher `podman save` |
| /srv/github/pennyroyal-validation | Tests | Bundle / Clone |
| /srv/github/hermes-memory-workspace | privates Hermes-Gedaechtnis-Repo (kein Remote!) | Bundle PFLICHT — sonst verloren |
| ~/.hermes (2 GB) | Hermes inkl. config.yaml, .env, skills, state.db | tar; danach `hermes update` |
| ~/.config/llm-infra | gateway.env, litellm.env, postgres.env, open-webui.env, chatgpt-tokens/, credentials.txt | tar, Rechte 0700/0600 beibehalten |
| ~/.config/containers/systemd | aktivierte Quadlets | aus Repo generieren (make apply-units), nicht zurueckkopieren |
| /srv/secrets/myconfigfiles | SSH-Keys, hf-token, Siemens-Token, Autopilot-Kram | age-verschluesselt oder manuell sichern |
| /srv/ai/models (281 GB) | RadixArk-Qwen3.8-Flash-Next-NVFP4 | NICHT sichern — neu laden via `scripts/40-download-model.sh` (hf, SSH-Remote git@hf.co moeglich; HF-Token aus /srv/secrets) |
| /srv/ai/nixl, /srv/ai/cache, /srv/ai/pennyroyal | ableitbarer Runtime-Kram | neu erzeugen |
| /srv/games | Steam | neu installieren, Bibliothek neu anlegen |

Vor dem Loeschen zwingend:

```bash
cd ~/work/llm-infra-setup
git -C . push; git -C /srv/github/pennyroyal push   # offene Branches!
./scripts/reinstall-preserve.sh /run/media/z000g9hu/Ventoy
./scripts/backup.sh /run/media/z000g9hu/Ventoy/backup-pre-ubuntu
sha256sum -c /run/media/z000g9hu/Ventoy/llm-preserve-*/SHA256SUMS
```

Das Pennyroyal-Image (localhost/pennyroyal:john-repair-5d33142c1, ca. 30–40 GB) vor
dem Wipe exportieren, falls der Image-Build nicht erneut durchlaufen soll:

```bash
podman save -o /run/media/z000g9hu/Ventoy/pennyroyal-john-repair-5d33142c1.tar \
  localhost/pennyroyal:john-repair-5d33142c1
```

## Ubuntu-Neuaufbau (Reihenfolge)

1. **OS:** Ubuntu 24.04 LTS, full-disk auf nvme1n1 p2+p3 als ZFS root (Installer
   „ZFS" wählen) ODER ext4 + separater srvpool wie bisher. /boot auf nvme1n1p1
   (vfat, 2,4G) behalten. Windows auf nvme0n1 bleibt unangetastet.
2. **Grundlagen:** `apt update && apt install -y podman buildah skopeo crun git git-lfs
   jq rsync openssh autossh python3-pip pipx age smartmontools shellcheck yamllint make
   zfsutils-linux nvidia-container-toolkit hfsprogs`
   (Ersetzt `scripts/10-install-packages.sh`; das Skript braucht einen apt-Zweig — siehe TODO.)
3. **NVIDIA-Treiber:** Ubuntu-Repo reicht moeglicherweise nicht fuer Blackwell-SM120;
   Ziel ist der neueste 570+/610er aus `graphics-drivers`-PPA oder NVIDIA-Linux.run.
   Nach Treiberwechsel IMMER CDI neu erzeugen:
   `sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml` (Pitfall: CDI-Datei
   zeigt nach Treiberupdate auf alte Bibliotheken -> Container startet nicht).
4. **ZFS srvpool:** `zpool create srvpool /dev/disk/by-id/...p2 ...p3 -o ashift=12`,
   Datasets `srvpool/github`, `srvpool/ai/{models,cache,nixl,pennyroyal}`, `srvpool/secrets`.
5. **Repos:** Bundle klonen, Remotes gegenprüfen, `git checkout <branch>`; Branches aus
   Bundle-Liste in README-repos.txt.
6. **Secrets:** ~/.config/llm-infra und /srv/secrets entpacken (0700/0600),
   `LITELLM_SALT_KEY` unveraendert lassen (sonst sind alle LiteLLM-Key-Hashes in der
   DB wertlos), chatgpt-tokens/ restaurieren.
7. **Setup-Skripte:** `./scripts/setup-qwen-pennyroyal.sh` — erst
   `00-preflight.sh`, dann Phasen 10–80. Auf Ubuntu sind Anpassungen noetig (siehe TODOs).
8. **Modell:** `./scripts/40-download-model.sh` (281 GB, hf-Download; Zeit einplanen).
9. **Image:** `podman load -i pennyroyal-john-repair-5d33142c1.tar` oder aus dem Fork
   neu bauen (Build-Jobs=8 Konvention beachten).
10. **Runtime/Gateway:** `make apply-units`, danach Verifikation wie unten.

## Verifikation nach dem Aufbau (Pflicht, dokumentiert im Repo)

* `systemctl --user is-active pennyroyal.service litellm.service litellm-postgres.service`
* Pennyroyal ready: `/health` 200 und `/v1/models` zeigt `pennyroyal`,
  `max_model_len=524288` (Laden dauert ~3–5 min; Status `starting` ist normal).
* Gateway keyless nur auf 127.0.0.1: `curl -s 127.0.0.1:4000/v1/models` ->
  qwen3.8-flash-next 524288, bonsai-2-27b 250000, gpt-6-luna 272000.
* Failover-Rauchtest: `./scripts/litellm-failover-drill.sh --no-luna`.
* Smoke durch die Kette: chat/completions auf `qwen3.8-flash-next`, Antwortfeld `model`
  muss `qwen3.8-flash-next` sein.
* Bewusst fehlender Bonsai ist GEWOLLT (Failover-Test der Kette qwen -> bonsai -> luna).
  Bonsai spaeter nachrüsten: llama.cpp-Container auf Port 8082, Alias bonsai-2-27b.
* Luna-Fallback: `reasoning_effort: medium`, `model_info.max_input_tokens: 272000`
  (unter der 272k-Preisstufe), ChatGPT-OAuth-Token via /etc/chatgpt-tokens.

## TODOs bis zum Schnitt (offene Arbeitspunkte)

* [ ] `10-install-packages.sh` apt-zweig + `00-preflight.sh` Ubuntu-tauglich machen
      (pacman->apt, zfs-Prüfung, Driver-Erkennung).
* [ ] `scripts/reinstall-preserve.sh` ausführen und Manifest prüfen.
* [ ] Pennyroyal-Image-Entscheidung: podman-save vs. Rebuild.
* [ ] /srv/github/hermes-memory-workspace: vor dem Wipe ein Remote anlegen
      (gh-Account hat nur Pull auf jpezzulli/*; neues privates Repo unter thomasdenk79-cyber?).
* [ ] sda3 NTFS ist unclean — vor dem Umbau mit ntfsfix pruefen/reparieren.
* [ ] Repo umbenennen in jpezzulli/llm-qwen38-flashnext-pennyroyal haengt an
      Admin-Rechten (siehe fact_store) — vor dem Umzug klaeren, sonst alter Remote.
* [ ] Ubuntu-Zielversion final bestaetigen (24.04.2 LTS angenommen).

Stand: 2026-10-11, erstellt von Hermes im Repo ~/work/llm-infra-setup.
