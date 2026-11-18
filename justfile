# just-Durchreicher auf das Makefile dieses Repos.
#
#   just              diese Liste
#   just <ziel>      ruft make <ziel> auf
#
# make bleibt die einzige Wahrheit fuer die Zieldefinitionen; hier stehen
# nur Einzeiler-Durchreicher fuer die taeglich gebrauchten Ablaeufe.
help:
	@make help

default: help

setup:
	@make setup

doctor:
	@make doctor

validate:
	@make validate

drift:
	@make drift

docs-build:
	@make docs-build

ci:
	@make ci

status:
	@make status

status-qualitaet:
	@make status-qualitaet

deploy-ready:
	@make deploy-ready
