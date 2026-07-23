.DEFAULT_GOAL := help
.PHONY: help test test-one results results-repo court set-known-good stop clean

SCRIPT := test/test-skill.sh
VERSION ?= 1.36.2
SPEC ?= all

help: ## Show available targets
	@echo "k8s-rebase test targets:"
	@echo ""
	@echo "  make test                            Run blind test suite (all repos)"
	@echo "  make test-one REPO=<r> [SPEC=<s>]    Test one repo (SPEC default: all)"
	@echo "  make results                         Show results matrix"
	@echo "  make results-repo REPO=<r>           Deep-dive one repo"
	@echo "  make court REPO=<r>                  Adversarial court review"
	@echo "  make set-known-good REPO=<r> BRANCH=<b>  Set reference branch for comparison"
	@echo "  make stop                            Stop all test sessions"
	@echo "  make clean                           Cleanup worktrees and mutated dirs"
	@echo ""
	@echo "Repos: openshift/multus-cni, ovn-org/ovn-kubernetes, etc."
	@echo "Specs: all, fn:<tag>, pattern:<key>, all-fns, all-patterns"

test: ## Run blind test suite across all repos
	@bash $(SCRIPT) test-all --version $(VERSION)

test-one: ## Test one repo: REPO=openshift/multus-cni [SPEC=all]
	@test -n "$(REPO)" || (echo "ERROR: REPO required. Usage: make test-one REPO=openshift/multus-cni" && exit 1)
	@bash $(SCRIPT) test $(SPEC) $(REPO) --version $(VERSION)

results: ## Show results matrix
	@bash $(SCRIPT) results

results-repo: ## Deep-dive one repo: REPO=openshift/multus-cni
	@test -n "$(REPO)" || (echo "ERROR: REPO required. Usage: make results-repo REPO=openshift/multus-cni" && exit 1)
	@bash $(SCRIPT) results $(REPO)

court: ## Adversarial court review: REPO=openshift/multus-cni
	@test -n "$(REPO)" || (echo "ERROR: REPO required. Usage: make court REPO=openshift/multus-cni" && exit 1)
	@bash $(SCRIPT) results $(REPO) --court

set-known-good: ## Set reference branch: REPO=openshift/multus-cni BRANCH=bump1.36
	@test -n "$(REPO)" || (echo "ERROR: REPO required. Usage: make set-known-good REPO=openshift/multus-cni BRANCH=bump1.36" && exit 1)
	@test -n "$(BRANCH)" || (echo "ERROR: BRANCH required. Usage: make set-known-good REPO=openshift/multus-cni BRANCH=bump1.36" && exit 1)
	@bash $(SCRIPT) set-known-good $(REPO) $(BRANCH)

stop: ## Stop all test sessions
	@bash $(SCRIPT) stop --all || true

clean: ## Cleanup worktrees and mutated dirs
	@bash $(SCRIPT) clean
