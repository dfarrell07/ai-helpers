---
name: block-vendor-edit
description: Prevent direct edits to vendored files during k8s-rebase
event: PreToolUse
tools:
  - Edit
  - Write
---

Check if the file path contains `/vendor/`. Vendored files are managed
by `go mod vendor` (run inside the rebase scripts). Direct edits to
vendor/ are erased by the next vendor sync, wasting significant time.

Block the operation if the file path matches:
- Any path containing `/vendor/` as a directory component

If the path matches, respond with:

```
BLOCK: Direct edits to vendor/ files are forbidden during k8s-rebase.
Vendor files are managed by `go mod vendor` inside the rebase scripts.
Any manual edits will be erased by the next vendor sync.

To fix vendored code: edit the upstream source in the dependency,
bump the dep version, and re-vendor.
```

If the path does NOT contain `/vendor/`, respond with:

```
ALLOW
```
