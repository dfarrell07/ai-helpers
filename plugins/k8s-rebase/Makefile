.DEFAULT_GOAL := help
.PHONY: help test test-one results court set-known-good stop clean

SCRIPT := test/test-skill.sh
VERSION ?= 1.36.2
SPEC ?= all
REPO ?= $(repo)
BRANCH ?= $(branch)

help: ## Show available targets
	@echo "k8s-rebase test targets:"
	@echo ""
	@echo "  make test                            Run blind test suite (3 at a time, re-run for next batch)"
	@echo "  make test-one repo=<r> [spec=<s>]    Test one repo (spec default: all)"
	@echo "  make results [repo=<r>]              Results matrix, or deep-dive one repo"
	@echo "  make court repo=<r>                  Adversarial court review"
	@echo "  make set-known-good repo=<r> branch=<b>  Set reference branch"
	@echo "  make stop                            Stop all test sessions"
	@echo "  make clean                           Cleanup worktrees and mutated dirs"
	@echo ""
	@echo "Repos: openshift/multus-cni, ovn-org/ovn-kubernetes, etc."
	@echo "Specs: all, fn:<tag>, pattern:<key>, all-fns, all-patterns"

test: ## Run blind test suite across all repos
	@bash $(SCRIPT) test-all --version $(VERSION)

test-one: ## Test one repo: make test-one repo=openshift/multus-cni
	@test -n "$(REPO)" || (echo "ERROR: repo required. Usage: make test-one repo=openshift/multus-cni" && exit 1)
	@bash $(SCRIPT) test $(SPEC) $(REPO) --version $(VERSION)

results: ## Results matrix, or deep-dive: make results repo=openshift/multus-cni
	@bash $(SCRIPT) results $(REPO)

court: ## Adversarial court review: make court repo=openshift/multus-cni
	@test -n "$(REPO)" || (echo "ERROR: repo required. Usage: make court repo=openshift/multus-cni" && exit 1)
	@bash $(SCRIPT) results $(REPO) --court

set-known-good: ## Set reference branch: make set-known-good repo=openshift/multus-cni branch=bump1.36
	@test -n "$(REPO)" || (echo "ERROR: repo required. Usage: make set-known-good repo=openshift/multus-cni branch=bump1.36" && exit 1)
	@test -n "$(BRANCH)" || (echo "ERROR: branch required. Usage: make set-known-good repo=openshift/multus-cni branch=bump1.36" && exit 1)
	@bash $(SCRIPT) set-known-good $(REPO) $(BRANCH)

stop: ## Stop all test sessions
	@bash $(SCRIPT) stop --all || true

clean: ## Cleanup worktrees and mutated dirs
	@bash $(SCRIPT) clean
