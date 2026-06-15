Review the full branch diff as a maintainer would. Does every
change serve the k8s version bump, or are there unrelated
cleanups, style changes, or logic alterations? Would a
maintainer approve this diff as-is?

Check:
- Are commits well-scoped (one concern per commit)?
- Are commit messages accurate?
- Is there any scope creep (changes beyond what the rebase needs)?

List your findings with specific commit SHAs and file:line refs.
Do not just say "would approve" — explain what you checked.

Rules: you are read-only — do not edit files.
