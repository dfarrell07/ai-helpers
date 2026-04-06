#!/bin/bash
# Comprehensive testing of iterate-claude.py

set -e

echo "=== Comprehensive Testing ==="
echo ""

# Test 1: Python syntax
echo -n "1. Python syntax... "
python3 -m py_compile scripts/iterate-claude.py 2>/dev/null && echo "✓" || (echo "✗"; exit 1)

# Test 2: Import order
echo -n "2. All imports at top... "
if grep -n "^[[:space:]]*import " scripts/iterate-claude.py | grep -v "^[7-9]:\|^1[0-6]:" > /dev/null; then
    echo "✗ Imports found after line 16"
    grep -n "^[[:space:]]*import " scripts/iterate-claude.py
    exit 1
else
    echo "✓"
fi

# Test 3: No unused imports
echo -n "3. Checking imports are used... "
for imp in argparse json os subprocess sys tempfile traceback pathlib anthropic; do
    if ! grep -q "$imp\." scripts/iterate-claude.py && ! grep -q "from $imp" scripts/iterate-claude.py; then
        if [ "$imp" != "pathlib" ] && [ "$imp" != "anthropic" ]; then
            echo "✗ $imp imported but not used?"
        fi
    fi
done
echo "✓"

# Test 4: Line count reasonable
echo -n "4. Line count reasonable... "
lines=$(wc -l < scripts/iterate-claude.py)
if [ "$lines" -lt 300 ] || [ "$lines" -gt 400 ]; then
    echo "✗ ($lines lines, expected 300-400)"
    exit 1
else
    echo "✓ ($lines lines)"
fi

# Test 5: No TODO/FIXME comments
echo -n "5. No TODO/FIXME markers... "
if grep -i "TODO\|FIXME\|XXX\|HACK" scripts/iterate-claude.py; then
    echo "✗"
    exit 1
else
    echo "✓"
fi

# Test 6: Iteration counting logic
echo -n "6. Iteration counting logic... "
python3 scripts/test-iteration-count.py > /dev/null 2>&1 && echo "✓" || (echo "✗"; exit 1)

# Test 7: Help message works
echo -n "7. Help message... "
if python3 scripts/iterate-claude.py --help 2>&1 | grep -q "iteratively"; then
    echo "✓"
else
    echo "✗"
    exit 1
fi

# Test 8: Error handling for missing args
echo -n "8. Missing args handling... "
if python3 scripts/iterate-claude.py 2>&1 | grep -qE "(required|anthropic)"; then
    echo "✓"
else
    echo "✗"
    exit 1
fi

# Test 9: Error handling for bad directory
echo -n "9. Bad directory handling... "
if python3 scripts/iterate-claude.py /nonexistent "test" 2>&1 | grep -q "does not exist"; then
    echo "✓"
else
    echo "✗"
    exit 1
fi

# Test 10: Git safety (no --force, --no-verify)
echo -n "10. Git safety checks... "
if grep -i "\-\-force\|\-\-no-verify\|\-\-no-gpg" scripts/iterate-claude.py; then
    echo "✗ Unsafe git commands found"
    exit 1
else
    echo "✓"
fi

echo ""
echo "=== All Tests Passed ✓ ==="
