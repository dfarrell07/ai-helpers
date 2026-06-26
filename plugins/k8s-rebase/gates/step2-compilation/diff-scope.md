Read each fix commit's diff (commits after the mechanical rebase,
before the autofix). Count files that are not Go source (.go),
tests (_test.go), module files (go.mod, go.sum), docs (.md),
CI configs (.yml/.yaml), or build files (Makefile, Dockerfile,
.sh). Vendor directory changes are also expected. Unexpected file
types suggest a fix leaked beyond its intended scope.

Report count of unexpected files changed.

Rules: report specific counts, not "looks good." You are
read-only — do not edit files. Cite file:line for any issues.
