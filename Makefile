# Front door for humans and agents. Swift commands need Xcode's toolchain.
SWIFT_PATHS := app/Sources app/Tests app/Package.swift scripts/make-icon.swift
PYTHON := helper/.venv/bin/python
APP := build/TidyParrot.app

.PHONY: help setup build run icon test test-swift test-helper integration smoke lint format clean

help: ## List targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-12s %s\n", $$1, $$2}'

setup: ## One-time: helper venv + pinned model download (~806 MB)
	scripts/setup.sh

build: ## Build build/TidyParrot.app; VERBATIM=1 keeps fillers (clean mode off)
	scripts/build.sh $(if $(VERBATIM),--verbatim)

run: build ## Build, quit any running copy, and launch the new one (accepts VERBATIM=1)
	-pkill -x TidyParrot && sleep 0.5
	open $(APP)

icon: ## Regenerate app/Resources/AppIcon.icns from app/Resources/AppIcon.png
	swift scripts/make-icon.swift app/Resources/AppIcon.png app/Resources/AppIcon.icns

test: test-swift test-helper ## All fast tests (no model needed)

test-swift: ## Swift unit tests
	swift test --package-path app

test-helper: $(PYTHON) ## Python protocol tests
	$(PYTHON) -m unittest discover -s helper/tests -t helper

integration: $(PYTHON) ## Swift engine against the real helper: make integration WAV=clip.wav
	@test -n "$(WAV)" || (echo "usage: make integration WAV=clip.wav" >&2; exit 2)
	TP_INTEGRATION_WAV="$(abspath $(WAV))" swift test --package-path app --filter HelperIntegrationTests
	TP_INTEGRATION_WAV="$(abspath $(WAV))" $(PYTHON) -m unittest discover -s helper/tests -t helper -p 'integration_*.py'

smoke: $(PYTHON) ## Python helper alone, real model: make smoke WAV=clip.wav
	@test -n "$(WAV)" || (echo "usage: make smoke WAV=clip.wav" >&2; exit 2)
	$(PYTHON) helper/smoke_test.py $(WAV)

lint: ## swift-format lint (strict)
	swift format lint --strict --recursive $(SWIFT_PATHS)

format: ## swift-format in place
	swift format --in-place --recursive $(SWIFT_PATHS)

clean: ## Remove build outputs (keeps venv and model)
	rm -rf build app/.build

$(PYTHON):
	@echo "Helper venv missing: run make setup first" >&2; exit 1
