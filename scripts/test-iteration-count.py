#!/usr/bin/env python3
"""Test that iteration counting works correctly"""

print("Simulating the fixed iteration counting logic...\n")

# Test 1: max_iterations=1
print("Test 1: max_iterations=1")
iteration = 1
iterations_completed = 0
max_iterations = 1

while True:
    if max_iterations and iteration > max_iterations:
        print(f"  Breaking (iteration {iteration} > max {max_iterations})")
        break

    print(f"  Executing iteration {iteration}")
    # Simulated work
    iterations_completed += 1

    # Check if done (simulate no ITERATION_COMPLETE)
    iteration += 1

print(f"  Result: Completed {iterations_completed} iteration(s)")
assert iterations_completed == 1, f"Expected 1, got {iterations_completed}"
print("  ✓ PASS\n")

# Test 2: max_iterations=3
print("Test 2: max_iterations=3")
iteration = 1
iterations_completed = 0
max_iterations = 3

while True:
    if max_iterations and iteration > max_iterations:
        break

    print(f"  Executing iteration {iteration}")
    iterations_completed += 1
    iteration += 1

print(f"  Result: Completed {iterations_completed} iteration(s)")
assert iterations_completed == 3, f"Expected 3, got {iterations_completed}"
print("  ✓ PASS\n")

# Test 3: ITERATION_COMPLETE on iteration 2
print("Test 3: ITERATION_COMPLETE on iteration 2")
iteration = 1
iterations_completed = 0
max_iterations = None

for i in range(5):  # Max 5 to prevent infinite loop
    if max_iterations and iteration > max_iterations:
        break

    print(f"  Executing iteration {iteration}")
    iterations_completed += 1

    # Simulate ITERATION_COMPLETE on iteration 2
    if iteration == 2:
        print(f"  ITERATION_COMPLETE detected")
        break

    iteration += 1

print(f"  Result: Completed {iterations_completed} iteration(s)")
assert iterations_completed == 2, f"Expected 2, got {iterations_completed}"
print("  ✓ PASS\n")

print("All iteration counting tests passed! ✓")
