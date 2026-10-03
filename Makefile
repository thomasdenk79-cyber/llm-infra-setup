# llm-infra-setup - Bedienung fuer Betreiber
#
#   make            diese Uebersicht
#   make setup      der eine Befehl fuer den Gesamtaufbau (idempotent)
#   make doctor     gefuehrter Check mit exakten naechsten Befehlen
#
# Alle Ablaeufe sind Skripte im Ordner scripts/ - nichts muss von Hand getippt
# werden. Details in README.md und docs/.
.PHONY: help setup setup-check preflight install tools nvidia-driver kwin-egpu podman zfs model model-verify pennyroyal ple-nvme verify-ple gateway litellm open-webui homepage portal autossh komodo postgres monitoring gpu-exporter collector watchdog watchdog-off gitops gitops-auto gitops-off tune tune-plan tune-conservative tune-sweet tune-sweet-an tune-maxkv tune-maxkv-an tune-rollback ple-native ple-copy ple-check ple-cache ple-warm gpu-frei gpu-frei-an gpu-frei-aus quality quality-lang quality-vergleich deploy deploy-all deploy-non-gpu deploy-ready apply-units wait healthcheck health backup restore doctor bench bench-normal bench-long validate drift ci status docs docs-build pre-commit-install checkpoint ungesichert tui rotate-secrets show-credentials

help:
	@echo 'llm-infra-setup - verfuegbare Befehle'
	@echo
	@echo 'Aufbau und Betrieb'
	@echo '  make setup             Gesamtaufbau, wiederholbar (./setup.sh)'
	@echo '  make setup-check       Aufbau-Pruefung ohne Aenderungen (./setup.sh --check)'
	@echo '  make doctor            gefuehrter Diagnose-Lauf mit naechsten Befehlen'
	@echo '  make preflight         Host-Zustand erfassen (state/preflight-report.txt)'
	@echo '  make install           fehlende Pakete installieren (braucht sudo)'
	@echo '  make zfs               Modell-Dataset anlegen bzw.pruefen'
	@echo '  make nvidia-driver     NVIDIA open DKMS einrichten (danach Neustart)'
	@echo '  make podman            rootless Podman, Linger, CDI, GPU-Test'
	@echo '  make model             Modell herunterladen (fortsetzbar)'
	@echo '  make model-verify      Modell vollstaendigkeit pruefen'
	@echo '  make pennyroyal        Image ziehen und Runtime-Unit erzeugen'
	@echo '  make ple-nvme          SSD-Speicher fuer Einbettungen vorbereiten'
	@echo '  make deploy            nur die GPU-Runtime starten'
	@echo '  make deploy-non-gpu    Portal, Chat, Gateway, Beobachtung (ohne GPU)'
	@echo '  make deploy-ready      kompletter Stack nach Neustart/GPU-Anschluss'
	@echo '  make apply-units       Unit-Aenderungen sicher overlegen (mit Schutz)'
	@echo '  make wait              auf die einsatzbereite Runtime warten'
	@echo
	@echo 'Beobachtung und Wartung'
	@echo '  make monitoring        Prometheus/Grafana/Loki/Dozzle/Portal installieren'
	@echo '  make gpu-exporter      GPU-Metriken-Einheit erzeugen'
	@echo '  make collector         Host-Kennzahlen (Timer alle 30 s)'
	@echo '  make watchdog          Runtime-Waechter aktivieren (warnt nur)'
	@echo '  make healthcheck       kurze Systempruefung'
	@echo '  make backup            Konfiguration, Datenbank, ZFS-Snapshot'
	@echo '  make restore           Wiederherstellungshilfe anzeigen'
	@echo '  make show-credentials  lokale Zugangsdaten anzeigen'
	@echo '  make rotate-secrets    Standard-Passwoerter durch Zufallswerte ersetzen'
	@echo '  make bench             Schnelltest (Vorlaufzeit und Schreibrate getrennt)'
	@echo
	@echo 'Aendern der Runtime-Werte (startet die Runtime neu!)'
	@echo '  make tune-plan         zeigt nur, was das Tuning aendern wuerde'
	@echo '  make tune              Tuning anwenden, messen, bei Schlechterstellung zurueck'
	@echo '  make tune-conservative kleinerer Eingriff (nur Speicher und HiCache)'
	@echo '  make tune-rollback     letzte Sicherung zurueckholen'
	@echo '  make tune-sweet-an     empfohlener Punkt fuer 2-4 grosse Sitzungen'
	@echo '  make tune-maxkv        zwei grosse Sitzungen statt vieler kleiner'
	@echo '  make gpu-frei          wer belegt gerade die Rechenkarte?'
	@echo '  make gpu-frei-an       Desktop von der Rechenkarte nehmen'
	@echo '  make quality           kurze Qualitaetspruefung (vor dem Tuning)   '
	@echo '  make quality-vergleich zwei Pruefungen vergleichen'
	@echo '  make ple-native        Blockflaeche fuer Einbettungen anlegen'
	@echo '  make ple-copy          Einbettungstabelle dorthin kopieren und pruefen'
	@echo '  make ple-cache         zeigt, wie viel davon im Arbeitsspeicher liegt'
	@echo
	@echo 'Qualitaet'
	@echo '  make validate          Syntax, YAML/JSON, Geheimnisse, Quadlets'
	@echo '  make drift             committete Units gegen Generatoren pruefen'
	@echo '  make docs-build        Doku strengen Test bauen lassen'
	@echo '  make status            Git-Zustand zeigen'

setup:
	./setup.sh
setup-check:
	./setup.sh --check
doctor:
	./scripts/doctor.sh
preflight:
	./scripts/00-preflight.sh
install:
	./scripts/10-install-packages.sh
tools:
	./scripts/15-install-tools.sh
nvidia-driver:
	./scripts/35-install-nvidia-driver.sh
kwin-egpu:
	./scripts/45-configure-kwin-egpu.sh
podman:
	./scripts/30-nvidia-podman.sh
zfs:
	./scripts/20-zfs-setup.sh
validate:
	./scripts/validate.sh
drift:
	./scripts/check-drift.sh
ci: validate drift docs-build
status:
	git status --short --branch
model:
	./scripts/40-download-model.sh
model-verify:
	./scripts/42-verify-model.sh
pennyroyal:
	./scripts/50-install-pennyroyal.sh
ple-nvme:
	./scripts/47-setup-ple-storage.sh
	./scripts/48-prepare-ple-nvme.sh
verify-ple:
	./scripts/47-setup-ple-storage.sh --verify
gateway:
	./scripts/60-install-gateway.sh
litellm:
	./scripts/70-litellm.sh
open-webui:
	./scripts/60-install-open-webui.sh
homepage:
	./scripts/60-install-homepage.sh
portal:
	./scripts/start-portal.sh
autossh:
	./scripts/61-install-autossh.sh
komodo:
	./scripts/62-install-komodo.sh
postgres:
	./scripts/63-install-postgres.sh
monitoring:
	./scripts/60-install-monitoring.sh
gpu-exporter:
	./scripts/65-install-gpu-exporter.sh
collector:
	./scripts/collect-host-facts.sh
	systemctl --user daemon-reload
	systemctl --user enable --now llm-infra-collect-facts.timer
watchdog:
	./scripts/runtime-watchdog.sh --install
watchdog-off:
	./scripts/runtime-watchdog.sh --uninstall
tune-plan:
	./scripts/apply-tuning.sh --nur-plan
tune:
	./scripts/apply-tuning.sh
tune-conservative:
	./scripts/apply-tuning.sh --profil konservativ
tune-sweet:
	./scripts/apply-tuning.sh --profil sweet --nur-plan
tune-sweet-an:
	./scripts/apply-tuning.sh --profil sweet
tune-maxkv:
	./scripts/apply-tuning.sh --profil maxkv --nur-plan
tune-maxkv-an:
	./scripts/apply-tuning.sh --profil maxkv
tune-rollback:
	./scripts/apply-tuning.sh --zurueck
ple-native:
	./scripts/46-create-ple-volume.sh
ple-copy:
	./scripts/49-migrate-ple.sh
ple-check:
	./scripts/49-migrate-ple.sh --nur-pruefen
ple-cache:
	./scripts/ple-preload.sh --status
ple-warm:
	./scripts/ple-preload.sh
gpu-frei:
	./scripts/44-isolate-blackwell.sh --zeige-nutzer
gpu-frei-an:
	./scripts/44-isolate-blackwell.sh
gpu-frei-aus:
	./scripts/44-isolate-blackwell.sh --ruckgaengig
quality:
	./scripts/quality_check.py --schnell
quality-lang:
	./scripts/quality_check.py
quality-vergleich:
	./scripts/quality_check.py --vergleich
gitops:
	./scripts/gitops-deploy.sh
gitops-auto:
	./scripts/install-gitops-timer.sh enable
gitops-off:
	./scripts/install-gitops-timer.sh disable
deploy:
	./scripts/deploy.sh
deploy-all:
	./scripts/deploy-all.sh
deploy-non-gpu:
	./scripts/deploy-non-gpu.sh
deploy-ready:
	./scripts/deploy-ready.sh
apply-units:
	./scripts/apply-runtime-unit.sh
wait:
	./scripts/wait-for-runtime.sh
healthcheck:
	./scripts/healthcheck.sh
health: healthcheck
backup:
	./scripts/backup.sh
restore:
	./scripts/restore.sh --list
show-credentials:
	./scripts/show-credentials.sh
rotate-secrets:
	./scripts/rotate-secrets.sh
bench:
	./scripts/benchmark.sh
bench-normal:
	./scripts/benchmark.sh normal
bench-long:
	./scripts/benchmark.sh long
tui:
	./tui/llmctl.py
docs:
	mkdocs serve
docs-build:
	mkdocs build --strict
checkpoint:
	./scripts/session-checkpoint.sh
ungesichert:
	./scripts/session-checkpoint.sh --status
pre-commit-install:
	pre-commit install
