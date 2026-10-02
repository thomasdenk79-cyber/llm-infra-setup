.PHONY: preflight install nvidia-driver kwin-egpu podman zfs model pennyroyal deploy healthcheck backup validate status
preflight:
	./scripts/00-preflight.sh
install:
	./scripts/10-install-packages.sh
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
deploy:
	./scripts/deploy.sh
healthcheck:
	./scripts/healthcheck.sh
backup:
	./scripts/backup-config.sh
