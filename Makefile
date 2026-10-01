.PHONY: preflight validate status
preflight:
	./scripts/00-preflight.sh
validate:
	./scripts/validate.sh
status:
	git status --short --branch
