#!/bin/bash
# Quick test to verify iterate-claude.py works without actually calling the API

echo "Testing iterate-claude.py..."
echo ""

# Check if anthropic is installed
if ! python3 -c "import anthropic" 2>/dev/null; then
    echo "⚠ anthropic package not installed"
    echo ""
    echo "Basic syntax tests:"

    # Test Python syntax
    echo -n "  Python syntax... "
    if python3 -m py_compile scripts/iterate-claude.py 2>/dev/null; then
        echo "✓"
    else
        echo "✗ FAILED"
        exit 1
    fi

    # Test that script loads
    echo -n "  Script loads... "
    if python3 scripts/iterate-claude.py 2>&1 | grep -q "anthropic package not installed"; then
        echo "✓"
    else
        echo "✗ FAILED"
        exit 1
    fi

    echo ""
    echo "Install dependencies to run full tests:"
    echo "  pip install -r requirements.txt"
    exit 0
fi

echo "Running full tests..."
echo ""

# Test 1: Missing directory
echo -n "Test 1: Missing directory arg... "
if python3 scripts/iterate-claude.py 2>&1 | grep -q "required"; then
    echo "✓"
else
    echo "✗ FAILED"
    exit 1
fi

# Test 2: Help message
echo -n "Test 2: Help message... "
if python3 scripts/iterate-claude.py --help 2>&1 | grep -q "iteratively"; then
    echo "✓"
else
    echo "✗ FAILED"
    exit 1
fi

# Test 3: Non-existent directory
echo -n "Test 3: Non-existent directory... "
if python3 scripts/iterate-claude.py /nonexistent "test" 2>&1 | grep -q "does not exist"; then
    echo "✓"
else
    echo "✗ FAILED"
    exit 1
fi

# Test 4: Missing API key
echo -n "Test 4: Missing API key detection... "
if ANTHROPIC_API_KEY= python3 scripts/iterate-claude.py /tmp "test" 2>&1 | grep -q "ANTHROPIC_API_KEY"; then
    echo "✓"
else
    echo "✗ FAILED"
    exit 1
fi

echo ""
echo "✓ All tests passed"
echo ""
echo "Note: Full integration test requires ANTHROPIC_API_KEY"
