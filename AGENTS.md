# Agentenleitfaden fuer dieses Repository

## Archiv-/WSL-Hinweis 2026-10-06

Dieser Branch wird unvermischt als historischer Versuch gesichert. Keine
Container/Runner automatisch starten und nicht als WSL-Installer verwenden.
Aktuelle Uebergabe: Basis-Branch `turbo-c6-production`, Datei
`docs/WSL-MIGRATION.md`; Source-Fork: `qwen38-flash-next-sm120/copilot-sm120`.

## Zweck

Versionierte Quelle der Wahrheit fuer die lokale LLM-Infrastruktur: CachyOS/Arch,
rootless Podman, ZFS, NVIDIA RTX PRO 6000, Pennyroyal/SGLang, LiteLLM, Open WebUI
und die Beobachtungsstapel (Prometheus, Grafana, Loki, Alloy, Dozzle).

## Grundregel 0: Arbeitsstand ist gesichert, bevor etwas anderes passiert

Das Repository ist das einzige Backup dieser Arbeit. Deshalb gilt fuer jeden Schritt:

```bash
./scripts/session-checkpoint.sh "kurze Notiz"     # pruefen, committen, pushen
```

* **Wann:** nach jedem abgeschlossenen Schritt, vor jedem riskanten Eingriff
  (Neustart der Laufzeit, Speicherveraenderungen, Unit-Aenderungen), und bevor
  eine Sitzung mit grossem Kontext fortgesetzt wird.
* Die Seite `docs/HANDOFF.md` ist der Fortsetzungsanker: Was gilt jetzt, was ist
  offen, welche Befehle braucht der naechste Leser. Das Skript aktualisiert deren
  Zeitstempel; inhaltliche Aenderungen gehoeren von Hand nachgepflegt.
* `state/` ist bewusst nicht in Git (Laufzeitkram). Arbeitsstaende, Messreihen und
  Protokolle, die jemand brauchen koennte, deshalb nach `docs/` oder als Auszug in
  `docs/HANDOFF.md` sichern - nie nur in `state/`.
* `./scripts/session-checkpoint.sh --status` zeigt, was noch ungesichert ist.
* Ein fehlgeschlagener Push (Netz, Rechner) bedeutet: nur lokal sicher. Dann erneut versuchen und
  im naechsten Schritt darauf hinweisen.

## Grundregeln

1. **Alles als Skript.** Dauerhafte Aenderungen entstehen zuerst als idempotentes
   Skript, Quadlet oder versionierte Konfiguration - danach ausfuehren, pruefen,
   dokumentieren, committen, pushen. Kein manueller Einzelbefehl ohne Skript.
2. **Die Grafikkarte gehoert dem Modell.** Kein zweiter Container, keine VM, kein
   Training mit GPU-Zugriff, `TP_SIZE` bleibt 1. Siehe `docs/adr/0013-*.md`.
3. **Nichts zerstoeren.** Keine `zpool create/destroy`, kein `zfs destroy`, kein
   `mkfs` auf vorhandenen Geraeten, kein Umschreiben von Benutzerdateien, die der
   Betreiber geaendert haben koennte (z. B. `~/.config/opencode/opencode.json`).
   Ein Skript, das eine vorhandene Datei ersetzen will, legt eine Vorlage daneben
   und erklaert den Unterschied.
4. **Laufende Anfragen nicht werfen.** Ein Neustart der Runtime kostet ~15
   Minuten. Aenderungen an Units ueber `scripts/apply-runtime-unit.sh` anwenden
   (bricht bei laufenden Anfragen ab); ein Neustart ist ein eigener, ausdruecklicher
   Schritt.
5. **Keine Geheimnisse im Git.** Zugangswerte werden erzeugt und liegen unter
   `~/.config/llm-infra/` (0600) oder als Podman-Secret. Beispiele enthalten nur
   Platzhalter. `make validate` prueft auf Standard-Passwoerter und Schluesselmuster.
6. **Deutsch fuer Menschen, Englisch fuer Logs.** Kommentare und Ausgabe fuer
   Betreiber sind Deutsch; maschinenlesbare Zeilen (`log`, Kennzahlen) Englisch.
7. **Einsteiger zuerst.** Jeder Pfad endet mit einer Ausgabe, die sagt, welcher
   Befehl als naechstes hilft. Faengt ein Skript mit einer Fehlermeldung auf,
   nennt sie den Befehl, nicht nur den Grund.

## Ablauf fuer jede Aenderung

1. Stand lesen: `README.md`, `docs/status.md`, `versions.lock`, betroffene Skripte.
2. Aenderung umsetzen (Skript, Quadlet, Konfiguration, Doku).
3. Statische Pruefung: `make validate`.
4. Wenn Units betroffen sind: `make drift` (Generatoren muessen die committeten
   Dateien exakt erzeugen).
5. Live-Anwendung, soweit ohne Runtime-Neustart moeglich:
   `./scripts/doctor.sh`, `./scripts/healthcheck.sh`, ggf. `./scripts/benchmark.sh quick`.
6. Doku nachziehen: betroffene `docs/*.md`, `CHANGELOG.md`, `docs/status.md`.
7. Commit mit praeziser Nachricht, nur zugehoerige Dateien stagen, dann pushen.

## Skript-Map

| Datei | Aufgabe |
|---|---|
| `setup.sh` | Einstieg, reicht weiter an `scripts/setup-qwen-pennyroyal.sh` |
| `scripts/setup-qwen-pennyroyal.sh` | Phasen 1-8 mit Statusdatei, Neustart-Pause, `--dry-run`, `--check` |
| `scripts/00-preflight.sh` | Read-only Hostaufnahme -> `state/preflight-report.txt`, `state/host-facts.txt` |
| `scripts/10-install-packages.sh` | fehlende Pakete installieren |
| `scripts/15-install-tools.sh` | Zusatzwerkzeuge, OpenCode, PATH fuer Bash/Fish |
| `scripts/20-zfs-setup.sh` | Dataset und ARC-Deckel, keine Zerstoerung |
| `scripts/30-nvidia-podman.sh` | rootless Podman, Linger, CDI (neu erzeugt), GPU-Test |
| `scripts/35-install-nvidia-driver.sh` | open DKMS, Nouveau-Ausschluss, Initramfs |
| `scripts/40-download-model.sh` | Modell laden, fortsetzbar |
| `scripts/42-verify-model.sh` | Index- und Shard-Pruefung, Revision in `versions.lock` |
| `scripts/45-configure-kwin-egpu.sh` | KWin-Grafikauswahl L15 (prueft Geraetename) |
| `scripts/47-setup-ple-storage.sh` | ext4-Loop oder echte Partition, `--verify` prueft fstab |
| `scripts/48-prepare-ple-nvme.sh` | PLE-Tabelle erzeugen (atomar, tmp-Ordner) |
| `scripts/50-install-pennyroyal.sh` | Bild ziehen, Digest pinnen, Runtime-Unit erzeugen |
| `scripts/60-install-gateway.sh` | LiteLLM-Konfiguration und Unit |
| `scripts/60-install-open-webui.sh` | Chat-Unit |
| `scripts/60-install-homepage.sh` | Portal-Unit |
| `scripts/60-install-monitoring.sh` | ganze Beobachtungsstufe inkl. Timer, `--check` |
| `scripts/61-install-autossh.sh` | optionaler Wartungstunnel, nur ein Schluessel, kein `apk add` zur Laufzeit |
| `scripts/62-install-komodo.sh` | optionale Periphery, bricht ohne echten Server ab |
| `scripts/63-install-postgres.sh` | Datenbank-Unit |
| `scripts/65-install-gpu-exporter.sh` | GPU-Metriken (nvidia-smi oder dcgm) |
| `scripts/collect-host-facts.sh` | Host-Kennzahlen als Textdatei fuer den node_exporter |
| `scripts/runtime-watchdog.sh` | wacht ueber die Runtime, `--install`/`--uninstall` |
| `scripts/wait-for-runtime.sh` | auf die API warten, Zeit als Umgebungsvariable |
| `scripts/deploy.sh` | nur Runtime |
| `scripts/deploy-non-gpu.sh` | ohne GPU: Portal, Chat, Gateway, Beobachtung |
| `scripts/deploy-ready.sh` | Vollstaendiger Einstieg nach Neustart, prueft Voraussetzungen |
| `scripts/deploy-all.sh` | Wrapper ueber mehrere Units (Betreiberaktion) |
| `scripts/apply-runtime-unit.sh` | Unit-Aenderungen sicher anwenden, `--list`, `--dry-run`, `--restart-only` |
| `scripts/doctor.sh` | gefuehrte Diagnose; Ausgabe endet mit dem naechsten Befehl |
| `scripts/healthcheck.sh` | Kurzpruefung; Langform ist `doctor.sh` |
| `scripts/benchmark.sh` + `benchmark_probe.py` | Messung von Vorlaufzeit und Schreibrate |
| `scripts/backup.sh` / `scripts/restore.sh` | Sicherung und Rueckgabe inkl. Pruefsummentest |
| `scripts/ensure-credentials.sh` / `show-credentials.sh` / `rotate-secrets.sh` | Zugangswerte |
| `scripts/check-drift.sh` | committete Units gegen Generatoren pruefen |
| `scripts/validate.sh` | Syntax, YAML/JSON, Quadlet, Geheimnisse, Pflichtdateien |
| `scripts/backup-config.sh` | alt, ruft nur noch `backup.sh` auf |
| `tui/llmctl.py` | Terminal-Zugriff auf dieselben Skripte |

## Einheiten und Netze

* `llm-inference`: Runtime, Gateway, Datenbank, Chat.
* `llm-observability`: Prometheus, Grafana, Loki, Alloy, Dozzle, Portal, Exporter.
* Prometheus haengt an beiden Netzen, die Runtime nur an einem
  (`docs/adr/0009-scrape-across-networks.md`).
* Unit-Dateien kommen aus `quadlet/`; generierte Dateien tragen einen Header
  `GENERIERT von ...`. Aendern im Generator, nicht in der Datei.

## Qualitaetspruefungen

```bash
make validate   # Syntax, YAML/JSON, Quadlet-Sektionen, Geheimnismuster, Pflichtdateien
make drift      # Generatoren erzeugen exakt die committeten Units
make docs-build # mkdocs --strict, kaputte Querverweise fallen auf
make ci         # alle drei
```

## Erweitern

Neue Dienste als Quadlet plus Generator-Skript plus Beispielkonfiguration plus
Doku-Abschnitt. Voraussetzungen, Ausführung, Fehlerdiagnose und Status
dokumentieren. Upstream-Versionen pruefen und in `versions.lock` festhalten.
Bei jedem neuen Dienst direkt mitdenken: Port nur auf `127.0.0.1`, Datenvolume
unter `~/.local/share/llm-infra`, Metrikziel in Prometheus, Diagnosefall in
`scripts/doctor.sh`.

## Bekannte offene Punkte

* Eigenes Seccomp-Profil statt `unconfined` fuer die Runtime.
* HTTPS und Firewallbetrachtung, falls das Netz jemals grosser wird.
* PLE auf echter NVMe-Partition gemessen gegen Loop-Datei (Anleitung in
  `docs/performance.md`).
* KVM/libvirt als spaetere, getrennte Phase (ohne GPU-Durchreichung).
