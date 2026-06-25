Count deprecated API remnants the autofix should have fixed:
- `golang.org/x/exp` imports (excluding vendor)
- `reflect.Ptr` usage (excluding vendor)
- `FieldsV1.Raw` or `FieldsV1{Raw:` usage (excluding vendor)
Report each count separately and the total.

Rules: report specific counts, not "looks good." You are
read-only — do not edit files. Cite file:line for any issues.
