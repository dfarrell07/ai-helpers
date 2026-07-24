.DEFAULT_GOAL := help
.PHONY: help test results court set-known-good stop clean

SCRIPT := test/test-skill.sh
VERSION ?= 1.36.2
SPEC ?= all
REPO ?= $(repo)
BRANCH ?= $(branch)

help: ## Show available targets
	@echo "k8s-rebase test targets:"
	@echo ""
	@echo "  make test [repo=<r>] [spec=<s>]      Test all repos (3 at a time), or one repo"
	@echo "  make results [repo=<r>]              Results matrix, or deep-dive one repo"
	@echo "  make court repo=<r>                  Adversarial court review"
	@echo "  make set-known-good repo=<r> branch=<b>  Set reference branch"
	@echo "  make stop                            Stop all test sessions"
	@echo "  make clean                           Cleanup worktrees and mutated dirs"
	@echo ""
	@echo "Repos: openshift/multus-cni, ovn-org/ovn-kubernetes, etc."
	@echo "Specs: all, fn:<tag>, pattern:<key>, all-fns, all-patterns"

test: ## Test all repos, or one: make test repo=openshift/multus-cni
	@if [ -n "$(REPO)" ]; then \
		bash $(SCRIPT) test $(SPEC) $(REPO) --version $(VERSION); \
	else \
		bash $(SCRIPT) test-all --version $(VERSION); \
	fi

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
