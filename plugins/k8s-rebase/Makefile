.DEFAULT_GOAL := help
.PHONY: help test watch results court set-known-good set-from-commit stop clean

SCRIPT := test/test-skill.sh
SPEC ?= none
REPO ?= $(repo)
BRANCH ?= $(branch)
COMMIT ?= $(commit)

help: ## Show available targets
	@echo "k8s-rebase test workflow:"
	@echo ""
	@echo "  make test                    Run tests (3 repos at a time, re-run for next batch)"
	@echo "  make watch                   Show progress (live: watch -n 10 make watch)"
	@echo "  make results                 Show results"
	@echo "  make stop                    Stop all sessions"
	@echo "  make clean                   Reset everything"
	@echo ""
	@echo "Options:"
	@echo "  make test repo=<r>           Test one repo"
	@echo "  make test spec=all           Blind test (remove all patterns/autofix)"
	@echo "  make results repo=<r>        Deep-dive one repo"
	@echo "  make court repo=<r>          Run adversarial court review"
	@echo ""
	@echo "Config: test/config.yaml"

test: ## Run tests
	@if [ -n "$(REPO)" ]; then \
		bash $(SCRIPT) test $(SPEC) $(REPO) $(if $(COMMIT),--from-commit $(COMMIT)); \
	else \
		bash $(SCRIPT) test-all; \
	fi

watch: ## Show active test status
	@bash $(SCRIPT) watch

results: ## Show results
	@bash $(SCRIPT) results $(REPO)

court: ## Adversarial court review
	@test -n "$(REPO)" || (echo "ERROR: repo required. Usage: make court repo=openshift/multus-cni" && exit 1)
	@bash $(SCRIPT) results $(REPO) --court

set-known-good: ## Set reference branch
	@test -n "$(REPO)" || (echo "ERROR: repo required" && exit 1)
	@test -n "$(BRANCH)" || (echo "ERROR: branch required" && exit 1)
	@bash $(SCRIPT) set-known-good $(REPO) $(BRANCH)

set-from-commit: ## Set pre-merge commit
	@test -n "$(REPO)" || (echo "ERROR: repo required" && exit 1)
	@test -n "$(COMMIT)" || (echo "ERROR: commit required" && exit 1)
	@bash $(SCRIPT) set-from-commit $(REPO) $(COMMIT)

stop: ## Stop all sessions
	@bash $(SCRIPT) stop --all || true

clean: ## Reset everything
	@bash $(SCRIPT) clean
