# k8s-rebase

Automate Kubernetes dependency rebases for Go projects that consume
`k8s.io/*` packages.

## What it does

When Kubernetes releases a new version, Go projects that depend on
`k8s.io/api`, `k8s.io/client-go`, etc. must bump all k8s.io/*
dependencies in lockstep. This plugin automates that process:

1. **Scans go.mod** to derive which packages need bumping (3 rules,
   97% coverage validated against 4 repos)
2. **Runs go get/tidy/vendor** for each module
3. **Updates codegen** if the repo has `hack/update-codegen.sh`
4. **Updates version references** across CI, docs, and Dockerfiles
5. **Validates** with build/lint/test, fixes breakage with agent
   guidance, and verifies fixes via antagonistic review

## Self-contained

All scripts, prompt templates, and pattern references are included
in this plugin. No companion files need to be installed in the
target repo. Just `cd` into the repo and run the skill.

## Usage

```text
/k8s-rebase:k8s-rebase 1.36.0
```

Run from the root of any Go repo with k8s.io dependencies.

## Contents

```
plugins/k8s-rebase/
├── scripts/
│   ├── k8s-rebase.sh              # Phases 0-3 orchestrator
│   ├── k8s-rebase-validate.sh     # Phase 4: error collection
│   ├── k8s-rebase-review.sh       # Phase 4: antagonistic review
│   └── k8s-rebase-review-prompt.md # Review agent prompt template
├── docs/
│   └── k8s-rebase-patterns.md     # Breakage pattern reference
├── skills/
│   └── k8s-rebase/
│       └── SKILL.md               # Skill entry point
└── README.md
```

## Tested against

- ovn-org/ovn-kubernetes (3 modules, codegen, vendor)
- openshift/multus-cni (1 module, vendor, no codegen)
- openshift/cluster-network-operator (1 module, vendor, codegen)
- openshift/cloud-network-config-controller (1 module, vendor)
