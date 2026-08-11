# Autofix Function Disposition

26 fix functions in `scripts/k8s-rebase-autofix.sh`, categorized by scope.

## Categories

| Cat | Meaning | Fires on |
|-----|---------|----------|
| Go  | Go language deprecations/migrations | Any repo with matching pattern |
| Imp | Import ordering and codegen tooling | Any repo with modified .go files |
| Ver | Version string updates (Go, k8s, lint) | Any repo with CI/docs version refs |
| CRD | CRD schema validation fixes | Repos with helm/*/crds/ or config/crd/ |
| NPA | network-policy-api conformance | ovnk (+ NPA itself) |
| KIND | KIND cluster and e2e infrastructure | Repos with KIND configs |
| Repo | Hardcoded repo-specific deps | ovnk only |

## Disposition Table

| # | Function | Cat | Self-gating guard | Disposition |
|---|----------|-----|-------------------|-------------|
| 1 | fix_xexp | Go | grep x/exp in *.go | keep |
| 2 | fix_reflect_ptr | Go | grep reflect.Ptr in *.go | keep |
| 3 | fix_klog_v2 | Go | grep klog v1 import | keep |
| 4 | fix_fieldsv1 | Go | K8S_MINOR >= 36 | keep |
| 5 | fix_eventf | Go | grep bare Eventf(.Error()) | keep |
| 6 | fix_addtoscheme | Imp | vendor has Install but no AddToScheme | keep |
| 7 | fix_imports | Imp | git diff shows modified .go files | keep |
| 8 | fix_bounding_dirs | Imp | hack/update-codegen.sh exists | keep |
| 9 | fix_mocks | Imp | .mockery.yaml exists | keep |
| 10 | fix_go_version | Ver | go.mod go directive vs CI files | keep |
| 11 | fix_lint_version | Ver | hack/lint.sh exists | keep |
| 12 | fix_version_refs | Ver | grep v1.OLD in CI/docs files | keep |
| 13 | fix_docs_version | Ver | docs/features/requirements.md exists | keep |
| 14 | fix_crd_int64_validation | CRD | grep maximum: 4294967295 in CRDs | keep |
| 15 | fix_crd_name_validation | CRD | helm CRDs + base branch comparison | keep |
| 16 | fix_conformance_renames | NPA | conformance NPA >= v0.2.0 | keep |
| 17 | fix_banp_egresspeer | NPA | BANP test file + vendor type check | keep |
| 18 | fix_obsgen | NPA | admin_network_policy/status.go exists | keep |
| 19 | fix_network_policy_api_crds | NPA | conformance NPA >= v0.2.0 | keep |
| 20 | fix_feature_gates | KIND | GATE_DEPS entries in vendor/k8s.io/ | keep |
| 21 | fix_kind_image | KIND | k8s.io/api in go.mod (NOT kindest/node grep) | keep |
| 22 | fix_kind_version | KIND | install-kind.sh exists | keep |
| 23 | fix_relaxed_svc_name | KIND | contrib/kind.yaml.j2 exists | keep |
| 24 | fix_kubeadm_v1beta4 | KIND | kind.yaml.j2 with kubeadm extraArgs | keep |
| 25 | fix_metallb_version | Repo | kind-common with metallb_version= | keep |
| 26 | fix_kubevirt_version | Repo | kind-common with KUBEVIRT_VERSION | keep |

## Key Finding

~9 of 26 functions only trigger on ovnk (or ovnk-adjacent repos like
network-policy-api). Specifically: all 4 NPA functions,
fix_relaxed_svc_name, fix_kubeadm_v1beta4, both Repo functions, plus
fix_docs_version. The remaining ~17 are
ecosystem-generic — they fire on any Go+k8s repo with the matching
pattern (including fix_feature_gates and fix_kind_image, which trigger
on any repo with vendored k8s.io/ deps).

Every function is self-gating: file-existence checks, grep guards, or
version comparisons ensure no-op on repos without matching files.

## Recommendation

Autofix stays default for production. Don't remove working self-gating
functions to optimize for a test mode. Discovery procedures (Step 3 of
the plan) are additive — they replace hardcoded version numbers with
runtime lookups, not delete functions.
