# Fleet hook baseline installer — logic lives in the hub .github/hooks/setup.sh.
.PHONY: all hooks help

all: hooks

hooks:
	@curl -fsSL https://raw.githubusercontent.com/mantit0985/.github/main/.github/hooks/setup.sh | sh

help:
	@echo "targets: hooks (install the fleet hook baseline via hub setup.sh)"
