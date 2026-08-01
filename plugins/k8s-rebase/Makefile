.DEFAULT_GOAL := help
.PHONY: help test watch results court set-known-good set-from-commit stop clean

SCRIPT := test/test-skill.sh
SPEC ?= $(if $(spec),$(spec),none)
REPO ?= $(repo)
REF ?= $(ref)
URL ?= $(url)
COMMIT ?= $(commit)
JOBS ?= $(jobs)
VER ?= $(version)
REPOS ?= $(repos_dir)
CONFIG ?= test/config$(if $(VER),-$(shell echo $(VER) | grep -oE '[0-9]+\.[0-9]+'),).yaml

help: ## Show available targets
	@echo ""
	@echo "  k8s-rebase skill testing"
	@echo "  ────────────────────────"
	@echo ""
	@echo "  Test"
	@echo "    make test                                Run all repos and wait for results (blocks until done)"
	@echo "    make test repo=<r>                       Test one repo"
	@echo "    make test repo=<r> commit=<sha>          Test from a specific historical commit"
	@echo "    make test spec=<s>                       Test with mutation (see specs below)"
	@echo "    make test version=1.35.2                 Test against an older k8s version"
	@echo ""
	@echo "  Monitor"
	@echo "    make watch                               Show test progress once"
	@echo "    watch -n 10 make watch                   Live dashboard (refreshes every 10s)"
	@echo ""
	@echo "  Results"
	@echo "    make results                             Summary for all repos (display only, no court)"
	@echo "    make results repo=<r>                    Deep-dive one repo (gates, diff, history)"
	@echo "    make court repo=<r>                      Adversarial court review (prosecution/defense/jury)"
	@echo ""
	@echo "  Manage"
	@echo "    make stop                                Stop all test sessions"
	@echo "    make clean                               Reset everything (worktrees, state, temp branches)"
	@echo ""
	@echo "  Config"
	@echo "    make set-known-good repo=<r> ref=<ref>          Set known-good reference (SHA or branch)"
	@echo "    make set-known-good repo=<r> ref=<b> url=<u>    Set known-good from fork branch"
	@echo "    make set-from-commit repo=<r> commit=<sha>      Set pre-merge commit for historical testing"
	@echo ""
	@echo "  Specs: none (default — full skill), all (blind — no patterns/autofix),"
	@echo "         fn:<tag> (disable one autofix fn), pattern:<key> (remove one pattern)"
	@echo ""
	@echo "  Repos: ovn-org/ovn-kubernetes, openshift/multus-cni, openshift/ingress-node-firewall,"
	@echo "         openshift/cloud-network-config-controller, openshift/cluster-network-operator,"
	@echo "         ovn-kubernetes/ovn-kubernetes-mcp"
	@echo ""
	@echo "  Versions: $(shell ls test/config-*.yaml 2>/dev/null | sed 's|test/config-||;s|\.yaml||' | tr '\n' ' ')"
	@echo "  Config file: test/config.yaml (version, max_concurrent, repos, known_good, from_commit)"
	@echo "  Repos dir: test/.repos/ (override: repos_dir=/path/to/repos)"
	@echo ""

test: ## Run tests
	@if [ -n "$(REPO)" ]; then \
		$(if $(JOBS),MAX_CONCURRENT=$(JOBS)) $(if $(REPOS),REPOS_DIR=$(REPOS)) CONFIG_FILE=$(CONFIG) bash $(SCRIPT) test $(SPEC) $(REPO) $(if $(COMMIT),--from-commit $(COMMIT)); \
	else \
		$(if $(JOBS),MAX_CONCURRENT=$(JOBS)) $(if $(REPOS),REPOS_DIR=$(REPOS)) CONFIG_FILE=$(CONFIG) bash $(SCRIPT) test-all $(SPEC); \
	fi

watch: ## Show active test status
	@$(if $(REPOS),REPOS_DIR=$(REPOS)) CONFIG_FILE=$(CONFIG) bash $(SCRIPT) watch

results: ## Show results
	@$(if $(REPOS),REPOS_DIR=$(REPOS)) CONFIG_FILE=$(CONFIG) bash $(SCRIPT) results $(REPO)

court: ## Adversarial court review
	@test -n "$(REPO)" || (echo "ERROR: repo required. Usage: make court repo=openshift/multus-cni" && exit 1)
	@$(if $(REPOS),REPOS_DIR=$(REPOS)) CONFIG_FILE=$(CONFIG) bash $(SCRIPT) results $(REPO) --court

set-known-good: ## Set known-good reference
	@test -n "$(REPO)" || (echo "ERROR: repo required" && exit 1)
	@test -n "$(REF)" || (echo "ERROR: ref required" && exit 1)
	@$(if $(REPOS),REPOS_DIR=$(REPOS)) CONFIG_FILE=$(CONFIG) bash $(SCRIPT) set-known-good $(REPO) $(REF) $(if $(URL),--url $(URL))

set-from-commit: ## Set pre-merge commit
	@test -n "$(REPO)" || (echo "ERROR: repo required" && exit 1)
	@test -n "$(COMMIT)" || (echo "ERROR: commit required" && exit 1)
	@$(if $(REPOS),REPOS_DIR=$(REPOS)) CONFIG_FILE=$(CONFIG) bash $(SCRIPT) set-from-commit $(REPO) $(COMMIT)

stop: ## Stop all sessions
	@$(if $(REPOS),REPOS_DIR=$(REPOS)) CONFIG_FILE=$(CONFIG) bash $(SCRIPT) stop --all || true

clean: ## Reset everything
	@$(if $(REPOS),REPOS_DIR=$(REPOS)) bash $(SCRIPT) clean
