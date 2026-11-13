# Front door for humans and agents. Swift commands need Xcode's toolchain.
SWIFT_PATHS := app/Sources app/Tests app/Package.swift
PYTHON := helper/.venv/bin/python
APP := build/TidyParrot.app

.PHONY: help setup build build-verbatim run test test-swift test-helper integration smoke lint format clean

help: ## List targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-15s %s\n", $$1, $$2}'

setup: ## One-time: helper venv + pinned model download (~806 MB)
	scripts/setup.sh

build: ## Build build/TidyParrot.app (clean mode)
	scripts/build.sh

build-verbatim: ## Build with clean mode off (keeps fillers)
	scripts/build.sh --verbatim

run: build ## Build and launch the app
	open $(APP)

test: test-swift test-helper ## All fast tests (no model needed)

test-swift: ## Swift unit tests
	swift test --package-path app

test-helper: ## Python protocol tests
	cd helper && .venv/bin/python -m unittest discover -s tests -t .

integration: ## Swift engine against the real helper: make integration WAV=clip.wav
	@test -n "$(WAV)" || (echo "usage: make integration WAV=clip.wav" >&2; exit 2)
	TP_INTEGRATION_WAV="$(abspath $(WAV))" swift test --package-path app --filter HelperIntegrationTests

smoke: ## Python helper alone, real model end to end: make smoke WAV=path/to/clip.wav
	@test -n "$(WAV)" || (echo "usage: make smoke WAV=clip.wav" >&2; exit 2)
	$(PYTHON) helper/smoke_test.py $(WAV)

lint: ## swift-format lint (strict)
	swift format lint --strict --recursive $(SWIFT_PATHS)

format: ## swift-format in place
	swift format --in-place --recursive $(SWIFT_PATHS)

clean: ## Remove build outputs (keeps venv and model)
	rm -rf build app/.build
