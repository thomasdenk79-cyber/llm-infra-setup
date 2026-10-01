.PHONY: preflight install podman validate status
preflight:
	./scripts/00-preflight.sh
install:
	./scripts/10-install-packages.sh
podman:
	./scripts/30-nvidia-podman.sh
validate:
	./scripts/validate.sh
status:
	git status --short --branch
