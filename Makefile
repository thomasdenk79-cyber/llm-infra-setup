.PHONY: docs docs-build pre-commit-install preflight install nvidia-driver kwin-egpu podman zfs model model-verify pennyroyal gateway litellm open-webui autossh komodo postgres deploy deploy-all deploy-non-gpu deploy-ready homepage portal healthcheck backup benchmark validate status
setup:
	./setup.sh

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
status:
	git status --short --branch

model:
	./scripts/40-download-model.sh
pennyroyal:
	./scripts/50-install-pennyroyal.sh
ple-nvme:
	./scripts/47-setup-ple-storage.sh
	./scripts/48-prepare-ple-nvme.sh
gateway:
	./scripts/60-install-gateway.sh
autossh:
	./scripts/61-install-autossh.sh
komodo:
	./scripts/62-install-komodo.sh
deploy:
	./scripts/deploy.sh
healthcheck:
	./scripts/healthcheck.sh
backup:
	./scripts/backup-config.sh

monitoring:
	./scripts/60-install-monitoring.sh

health: healthcheck
model-download: model
start:
	./tui/llmctl.py start
stop:
	./tui/llmctl.py stop
restart:
	./tui/llmctl.py restart
logs:
	./tui/llmctl.py logs
benchmark:
	./scripts/benchmark.sh

litellm:
	./scripts/70-litellm.sh
open-webui:
	./scripts/60-install-open-webui.sh
homepage:
	./scripts/60-install-homepage.sh
portal:
	./scripts/start-portal.sh
deploy-all:
	./scripts/deploy-all.sh
deploy-non-gpu:
	./scripts/deploy-non-gpu.sh
deploy-ready:
	./scripts/deploy-ready.sh

postgres:
	./scripts/63-install-postgres.sh

docs:
	mkdocs serve
docs-build:
	mkdocs build --strict

pre-commit-install:
	pre-commit install

model-verify:
	./scripts/42-verify-model.sh
