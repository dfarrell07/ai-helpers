.DEFAULT_GOAL := help
.PHONY: help test watch results court set-known-good set-from-commit stop clean

SCRIPT := test/test-skill.sh
SPEC ?= none
REPO ?= $(repo)
BRANCH ?= $(branch)
COMMIT ?= $(commit)
JOBS ?= $(jobs)

help: ## Show available targets
	@echo ""
	@echo "  k8s-rebase skill testing"
	@echo "  ────────────────────────"
	@echo ""
	@echo "  Test"
	@echo "    make test                                Run all repos (max_concurrent from config.yaml, or: make test jobs=6)"
	@echo "    make test repo=<r>                       Test one repo"
	@echo "    make test repo=<r> commit=<sha>          Test from a specific historical commit"
	@echo "    make test spec=<s>                       Test with mutation (see specs below)"
	@echo ""
	@echo "  Monitor"
	@echo "    make watch                               Show test progress once"
	@echo "    watch -n 10 make watch                   Live dashboard (refreshes every 10s)"
	@echo ""
	@echo "  Results"
	@echo "    make results                             Summary for all repos"
	@echo "    make results repo=<r>                    Deep-dive one repo (gates, diff, history)"
	@echo "    make court repo=<r>                      Adversarial court review (prosecution/defense/jury)"
	@echo ""
	@echo "  Manage"
	@echo "    make stop                                Stop all test sessions"
	@echo "    make clean                               Reset everything (worktrees, state, temp branches)"
	@echo ""
	@echo "  Config"
	@echo "    make set-known-good repo=<r> branch=<b>  Set reference branch for diff comparison"
	@echo "    make set-from-commit repo=<r> commit=<sha>  Set pre-merge commit for historical testing"
	@echo ""
	@echo "  Specs: none (default — full skill), all (blind — no patterns/autofix),"
	@echo "         fn:<tag> (disable one autofix fn), pattern:<key> (remove one pattern)"
	@echo ""
	@echo "  Repos: ovn-org/ovn-kubernetes, openshift/multus-cni, openshift/ingress-node-firewall,"
	@echo "         openshift/cloud-network-config-controller, openshift/cluster-network-operator,"
	@echo "         ovn-kubernetes/ovn-kubernetes-mcp"
	@echo ""
	@echo "  Config file: test/config.yaml (version, max_concurrent, repos, known_good, from_commit)"
	@echo ""

test: ## Run tests
	@if [ -n "$(REPO)" ]; then \
		$(if $(JOBS),MAX_CONCURRENT=$(JOBS)) bash $(SCRIPT) test $(SPEC) $(REPO) $(if $(COMMIT),--from-commit $(COMMIT)); \
	else \
		$(if $(JOBS),MAX_CONCURRENT=$(JOBS)) bash $(SCRIPT) test-all $(SPEC); \
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
