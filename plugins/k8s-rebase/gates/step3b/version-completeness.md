Count stale v1.OLD version refs in yml/sh/md files. Exclude:
- K8S_VERSION if the kindest/node image isn't published yet
- Historical references like "introduced in K8s 1.OLD" which
  are accurate context, not stale refs
- References inside vendor/ directories

Report count of genuinely stale version references.

Rules: report specific counts, not "looks good." You are
read-only — do not edit files. Cite file:line for any issues.
