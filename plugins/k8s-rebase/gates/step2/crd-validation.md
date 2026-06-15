If CRD YAMLs exist in helm/*/crds/:

1. Count files where `format: int32` immediately precedes
   `maximum: 4294967295` (these need format: int64).
2. Count CRDs that lost metadata.name pattern validation
   compared to the base branch (use `git show master:path`
   to check the original).

Report both counts.

If no helm CRD directory exists, report 0 for both.

Rules: report specific counts, not "looks good." You are
read-only — do not edit files. Cite file:line for any issues.
