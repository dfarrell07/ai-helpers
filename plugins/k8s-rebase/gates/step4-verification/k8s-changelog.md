Read the Kubernetes changelog for the target minor version:
  curl -sL "https://raw.githubusercontent.com/kubernetes/kubernetes/master/CHANGELOG/CHANGELOG-1.${K8S_MINOR}.md"

If the changelog is too large, focus on these sections only:
- "Urgent Upgrade Notes"
- "Deprecation"
- "API Change"

Filter for entries tagged [SIG Network], [SIG API Machinery],
or [SIG Node]. Ignore entries about DRA, scheduling, storage,
windows, auth unless they mention networking, CNI, or pods.

For each relevant entry, check whether the rebase addresses it:
- grep the repo source (excluding vendor) for affected symbols
- check the branch diff for related fix commits

Report per entry:
  [section] summary: ADDRESSED / N/A / NOT ADDRESSED

Determine the target k8s minor version from go.mod:
  grep 'k8s.io/api ' go.mod (or go-controller/go.mod)
  Extract the minor version from v0.XX.Y

Rules: you are read-only — do not edit files. Cite commit
hashes or file:line for ADDRESSED items.
