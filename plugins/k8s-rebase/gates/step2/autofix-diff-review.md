Read the autofix commit's diff. For each code change, verify it
is a correct transformation:
- x/exp→stdlib: maps.Keys wrapped in slices.Collect? imports
  in the stdlib section (not third-party)?
- FieldsV1: .Raw→.GetRawBytes()? {Raw: []byte(...)}→NewFieldsV1(...)?
- Format strings: correct verbs? Eventf has format directive?
- Feature gates: all gates in the right places?

List each transformation category you checked and your finding.

Rules: you are read-only — do not edit files. Cite file:line
for any issues.
