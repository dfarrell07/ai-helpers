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
	@echo "  make test                              Run tests (3 repos at a time, re-run for next batch)"
	@echo "  make test repo=<r>                     Test one repo"
	@echo "  make test repo=<r> commit=<sha>        Test from a specific commit"
	@echo "  make test spec=all                     Blind test (remove all patterns/autofix)"
	@echo ""
	@echo "  make watch                             Show test progress (live: watch -n 10 make watch)"
	@echo ""
	@echo "  make results                           Show results for all repos"
	@echo "  make results repo=<r>                  Deep-dive one repo"
	@echo "  make court repo=<r>                    Run adversarial court review on one repo"
	@echo ""
	@echo "  make stop                              Stop all test sessions"
	@echo "  make clean                             Reset everything (worktrees, state, temp branches)"
	@echo ""
	@echo "  make set-known-good repo=<r> branch=<b>    Set reference branch for comparison"
	@echo "  make set-from-commit repo=<r> commit=<sha> Set pre-merge commit for historical testing"
	@echo ""
	@echo "Config: test/config.yaml (repos, version, known-good, from-commit)"

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
