# Handoff 2026-10-03 (Zustand vor dem naechsten Schritt)

Dieser Stand ist wichtig, wenn eine Sitzung abbricht, der Rechner neu startet oder
ein anderer Agent weiterarbeiten muss. Alles hier ist bereits im Repository; diese
Seite sammelt nur die Fadenenden.

## Wo das System steht (gemessen 2026-10-03, 07:15)

* Runtime Pennyroyal v2.5.3 laeuft, API gesund, VRAM 94,9 / 97,9 GiB.
* Kapazität der Laufzeit (wichtig fuer mehrere opencode-Sitzungen):
  * `sglang:context_len` = **524288** Token maximal pro Anfrage
  * `sglang:max_total_num_tokens` = **824384** Token gemeinsamer Speicher fuer ALLE
    gleichzeitigen Anfragen
  * gemessen: `kv_used_tokens` 522496 bei 2 laufenden Anfragen, `kv_available_tokens` 448,
    `kv_evictable_tokens` 301440, `mamba_used` 8 / `mamba_available` 2
  * Bedeutung: zwei Sitzungen mit je 250-300k Kontext fuellen den Pool fast;
    ab der dritten wird verdraengt (Verdraengung = Vorlesen wiederholen = langsam).
  * Empfehlung an den Betreiber: ab etwa 300k Kontext pro Sitzung `compact` benutzen
    oder den Kontext im Client begrenzen (siehe `opencode.json.llm-infra`).
* Messwerte Schreibrate (Vorlaufzeit getrennt): 157,9 / 119,0 Token/s pro Anfrage,
  242,5 Token/s gesamt bei vier gleichzeitigen Anfragen.

## Laeuft gerade (nicht abbrechen!)

* Umzug der PLE-Tabelle auf das neue native Volumen:
  Log `state/ple-migrate.log`, Fortschritt auch mit `df -h /srv/llm/ple-native`.
  Dauer: 48 GiB, etwa 15-25 Minuten.
* Pruefen nach Abschluss: `./scripts/49-migrate-ple.sh --nur-pruefen`
* Status des Seitenspeichers: `./scripts/ple-preload.sh --status`

## Was neu eingerichtet ist

* **Native Flaeche fuer PLE**: ZFS-Volumen `zpcachyossrv/srv/ple-vol` (80 GiB duenn,
  volblocksize 4K), ext4 mit 4K-Blöcken, eingehaengt auf `/srv/llm/ple-native`,
  `noatime,nodiratime` und `nofail` in `/etc/fstab`.
  Angelegt von `scripts/46-create-ple-volume.sh` (formatiert NACH ausdruecklicher
  Freigabe durch den Betreiber).
* Grund fuer ein Volumen statt einer echten Partition: Die Scheibe ist ein
  einziges 512-GiB-Laufwerk, aufgeteilt in zwei ZFS-Pools. ZFS-Vdevs lassen sich
  NICHT verkleinern, eine neue Partition gaebe es nur nach Neuinstallation oder
  mit einer zweiten SSD. Siehe `docs/adr/0011-*.md` (Stand 2026-10-03).
* Page-Cache-Analyse: `scripts/lib/page_cache_status.py` (mincore), damit sichtbar
  ist, wie viel der Tabelle wirklich im RAM liegt.

## Noch offen (Reihenfolge)

1. Umzug abschliessen und pruefen (Punkt oben).
2. `config/host.env`: `PENNY_PLE_NVME_MODEL=/srv/llm/ple-native/...` und
   `PENNY_HICACHE_SIZE_GB=16` setzen; danach `make pennyroyal`.
3. `./scripts/apply-tuning.sh` - das autonome Skript fuer die heisse Phase
   (Vorher/Nachher-Messung, automatischer Rückfaller, Protokoll in `state/tuning/`).
   Es startet die Runtime neu; laeuft das, stirbt diese Sitzung.
4. Doku-Korrekturen, die auf Fakten beruhen:
   * `docs/adr/0012-*.md`, `docs/performance.md` und der Doctor-Hinweis behaupteten,
     die Thunderbolt-Anbindung sei die Durchsatzgrenze. **Nachgemessen falsch**:
     waehrend der Schreibphase fließen ueber die Strecke nur 3-25 MB/s
     (`nvidia-smi dmon -s t`). Die Karte ist zu 61 % ausgelastet, Temperatur okay,
     Leistungsverbrauch 275 W von 600 W Limit. Die Grenze liegt in den
     Rechen-/Cache-Pfaden der Laufzeitumgebung, nicht in der Strecke.
5. `docs/COMPLIANCE.md` liegt bei; nach dem Umzug die Tabelle dort aktualisieren
   (PLE auf nativem Volumen, HiCache 16 GiB).
6. Später: eigenes Seccomp-Profil, DCGM-Vergleich, Komodo/Tunnel mit echten
   Zugangsdaten, Neustart-Test der Autostarts.

## Befehle, die der naechste Leser braucht

```bash
./scripts/doctor.sh                    # gefuehrte Diagnose
tail -3 state/ple-migrate.log          # Umzug-Fortschritt
./scripts/49-migrate-ple.sh --nur-pruefen
./scripts/ple-preload.sh --status      # liegt die Tabelle im RAM?
./scripts/apply-runtime-unit.sh --list # Repo gegen Laeufer
make validate && make drift            # Repo-Pruefungen
MIN_TOKENS=150 ./scripts/benchmark.sh normal
```

## Grundregeln (nicht verhandelbar)

* Die Grafikkarte gehoert dem Modell: TP1, kein zweiter GPU-Nehmer (`ADR 0013`).
* Laeuft die Runtime, ist ein Neustart ein ausdruecklicher Schritt
  (`PENNYROYAL_PROTECT=1` als Sperre, `apply-tuning.sh` wartet auf leere Warteschlange).
* Vorhandene Nutzerdateien werden nicht ueberschrieben; Vorlagen liegen daneben.
* Keine `zfs destroy`/`zpool`-Eingriffe, kein Formatieren ohne Bestaetigung.
