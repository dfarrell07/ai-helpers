# macOS Compatibility Issues and Fixes

This document catalogs macOS compatibility issues discovered during k8s-rebase execution and their fixes.

## Overview

The k8s-rebase script was developed on Linux and makes assumptions about GNU tooling that don't hold on macOS (BSD-based tools). This caused multiple failures when running on macOS.

## Issues and Solutions

### 1. `/dev/stdin` Not Supported with `go mod edit`

**Error:**
```
go: RLock /dev/stdin: operation not supported
```

**Location:** `k8s-rebase.sh` - go mod edit operations

**Root Cause:**
macOS does not support file operations on `/dev/stdin` the same way Linux does. When using process substitution with `go mod edit -json /dev/stdin`, macOS fails with "operation not supported".

**Occurrence:**
```bash
_mod=$(go mod edit -json /dev/stdin <<<'{"require": {...}}')
```

**Fix:**
Use a temporary file instead of `/dev/stdin`:
```bash
_tmpmod=$(mktemp)
echo "$_json" > "$_tmpmod"
_mod=$(go mod edit -json "$_tmpmod")
rm -f "$_tmpmod"
```

**Impact:** Critical - Script fails immediately in Phase 1

---

### 2. BSD `sed` Incompatibility - In-Place Edit Syntax

**Error:**
```
sed: 1: "s|(ENVTEST_K8S_VERSION[...": \1 not defined in the RE
sed: 1: "./Makefile": invalid command code .
```

**Location:** `k8s-rebase.sh`, `k8s-rebase-autofix.sh` - All `sed -i` commands

**Root Cause:**
GNU sed and BSD sed have different syntax for in-place editing:
- GNU sed: `sed -i 's/pattern/replacement/' file`
- BSD sed: `sed -i '' 's/pattern/replacement/' file`

BSD sed requires an explicit extension argument (use empty string `''` for no backup).

**Occurrence:**
```bash
sed -i "s|ENVTEST_K8S_VERSION.*|ENVTEST_K8S_VERSION = $VERSION|" Makefile
```

**Fix:**
Add empty string argument after `-i`:
```bash
sed -i '' "s|ENVTEST_K8S_VERSION.*|ENVTEST_K8S_VERSION = $VERSION|" Makefile
```

**Detection:**
```bash
if sed --version 2>&1 | grep -q GNU; then
    SED_INPLACE="sed -i"
else
    SED_INPLACE="sed -i ''"
fi
```

**Impact:** Critical - Fails during version reference updates (Phase 3)

---

### 3. BSD `sed` - Invalid `-E` Usage

**Error:**
```
sed: -E: No such file or directory
```

**Root Cause:**
When `-E` and `-i` are combined incorrectly on BSD sed, it treats `-E` as a filename.

**Occurrence:**
```bash
sed -i -E 's/pattern/replacement/' file
```

**Fix:**
Ensure correct order and spacing:
```bash
sed -i '' -E 's/pattern/replacement/' file
```

**Impact:** Medium - Breaks regex-based replacements

---

### 4. Missing GNU `timeout` Command

**Error:**
```
timeout: command not found
```

**Location:** Gate validation scripts that use `timeout` command

**Root Cause:**
GNU `timeout` is not available on macOS by default. It's part of GNU coreutils but not in the default PATH.

**Occurrence:**
```bash
timeout 300 make lint
```

**Fix Option 1 - Install via Homebrew:**
```bash
brew install coreutils
# Creates gtimeout, not timeout
```

**Fix Option 2 - Create wrapper:**
```bash
# Add to PATH
mkdir -p /tmp/k8s-rebase-bin
cat > /tmp/k8s-rebase-bin/timeout << 'EOF'
#!/bin/bash
gtimeout "$@"
EOF
chmod +x /tmp/k8s-rebase-bin/timeout
export PATH="/tmp/k8s-rebase-bin:$PATH"
```

**Fix Option 3 - Make timeout optional:**
```bash
if command -v timeout >/dev/null 2>&1; then
    timeout 300 make lint
else
    make lint
fi
```

**Impact:** Medium - Gates fail, but validation still runs

---

### 5. Missing `yq` Binary

**Error:**
```
yq binary not found
make: *** [manifests] Error 1
```

**Location:** Makefile targets that depend on `yq`

**Root Cause:**
`yq` is not installed by default on macOS and is required for CRD generation.

**Occurrence:**
```bash
make manifests
```

**Fix:**
Install yq:
```bash
go install github.com/mikefarah/yq/v4@latest
```

**Recommended Fix (in script):**
```bash
# Check and install yq if missing
if ! command -v yq >/dev/null 2>&1; then
    echo ":: Installing yq..."
    go install github.com/mikefarah/yq/v4@latest
fi
```

**Impact:** Medium - Codegen/manifest generation fails

---

### 6. Different Behavior of `find -regex`

**Root Cause:**
macOS uses BSD `find` which has different regex syntax than GNU `find`:
- GNU find: Uses Emacs-style regex by default
- BSD find: Uses basic regex, requires `-E` for extended

**Occurrence:**
```bash
find . -regex '.*\.\(go\|yaml\)'
```

**Fix:**
Use `-E` flag for extended regex on macOS:
```bash
find -E . -regex '.*\.(go|yaml)'
```

Or use simpler glob patterns:
```bash
find . -name "*.go" -o -name "*.yaml"
```

**Impact:** Low - File searches may return incorrect results

---

## Comprehensive Fix Strategy

### Detection Script

Add OS detection at the beginning of scripts:

```bash
#!/bin/bash

# Detect OS
OS="$(uname -s)"
case "$OS" in
    Darwin*)
        OS_TYPE="macos"
        SED_INPLACE="sed -i ''"
        ;;
    Linux*)
        OS_TYPE="linux"
        SED_INPLACE="sed -i"
        ;;
    *)
        echo "Warning: Unknown OS $OS, assuming Linux-like"
        OS_TYPE="linux"
        SED_INPLACE="sed -i"
        ;;
esac
```

### Portable sed Function

```bash
portable_sed() {
    local pattern="$1"
    local file="$2"
    
    if [[ "$OS_TYPE" == "macos" ]]; then
        sed -i '' "$pattern" "$file"
    else
        sed -i "$pattern" "$file"
    fi
}
```

### File Input Instead of stdin

```bash
# Instead of:
go mod edit -json /dev/stdin <<<'{"require": {...}}'

# Use:
tmpfile=$(mktemp)
trap "rm -f $tmpfile" EXIT
echo '{"require": {...}}' > "$tmpfile"
go mod edit -json "$tmpfile"
```

---

## Testing

### Verification Checklist

- [ ] Script runs on macOS (Intel and Apple Silicon)
- [ ] Script runs on Linux
- [ ] All sed operations work correctly
- [ ] Temporary files are created and cleaned up
- [ ] timeout commands don't break execution
- [ ] yq is available or installed automatically

### Test Platforms

- macOS 13+ (Ventura, Sonoma)
- Linux (Ubuntu 22.04, RHEL 9)
- Container environments (both Linux and macOS Docker)

---

## Summary of Files Requiring Changes

1. **plugins/k8s-rebase/scripts/k8s-rebase.sh**
   - Fix /dev/stdin usage (5 locations)
   - Fix sed -i syntax (15+ locations)
   - Add OS detection

2. **plugins/k8s-rebase/scripts/k8s-rebase-autofix.sh**
   - Fix sed -i syntax (30+ locations)
   - Fix timeout usage
   - Add yq installation check

3. **plugins/k8s-rebase/scripts/k8s-rebase-orchestrator.sh**
   - Add OS-specific setup
   - Handle missing tools gracefully

4. **Gate scripts**
   - Make timeout optional
   - Use portable sed

---

## Future Improvements

1. **Container-based execution:**
   - Provide a Docker/Podman option to run in a controlled Linux environment
   - Eliminates platform differences entirely

2. **Tool installation automation:**
   - Auto-detect and install missing tools
   - Provide clear instructions for manual installation

3. **CI Testing:**
   - Add macOS to CI pipeline
   - Test on both platforms before merge

---

## References

- [GNU sed vs BSD sed](https://riptutorial.com/sed/example/2594/bsd-macos-sed-vs--gnu-sed-vs--the-posix-sed-specification)
- [macOS /dev/stdin limitations](https://unix.stackexchange.com/questions/521278/dev-stdin-not-working-on-macos)
- [Portable shell scripting](https://www.gnu.org/software/autoconf/manual/autoconf-2.69/html_node/Portable-Shell.html)
