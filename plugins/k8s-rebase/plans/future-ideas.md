# Future Ideas

Ideas for after the skill is reliable and general. Not planned —
just tracked so they don't get lost.

- Multi-repo coordinator (dependency-ordered batch execution,
  `depends_on` in config.yaml)
- Fleet dashboard (blocked/in-progress/pass/fail per repo)
- Downstream handling (openshift/ovn-kubernetes OTE module)
- License scan gate (`go-licenses` before PR command)
- Feature gate policy layer (flag newly-defaulted gates for human
  review instead of silently disabling — upstream needs breakage
  reports)
- Builder image validation (check ART image availability before
  updating Dockerfile refs)
- Discovery procedures (replace version-specific recipes with
  runtime detection: vendor probing, GitHub API for infra versions,
  Go/lint version matrix)
- Model-version coupling (log model ID per run, watch Tier 1 pass
  rates after model updates, pin on regression)
- Operator-sdk/controller-tools automation (currently agent handles
  in steps 2/4, no deterministic script)
- Non-vendored feature gate discovery (scan $GOMODCACHE instead
  of vendor/)
