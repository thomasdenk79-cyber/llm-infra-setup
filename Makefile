.PHONY: preflight install podman zfs validate status
preflight:
	./scripts/00-preflight.sh
install:
	./scripts/10-install-packages.sh
podman:
	./scripts/30-nvidia-podman.sh
zfs:
	./scripts/20-zfs-setup.sh
validate:
	./scripts/validate.sh
status:
	git status --short --branch
