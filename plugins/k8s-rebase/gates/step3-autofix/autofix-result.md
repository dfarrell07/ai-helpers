Read the autofix script output in `.rebase-tmp/`. Look for
files matching `autofix*.log` or check the terminal output
from the autofix step. If RESULT is FAIL, report which checks
failed and their counts. Count WARNING lines. If the output
is empty or missing, report that the autofix may not have run.
Report total issues.

Rules: report specific counts, not "looks good." You are
read-only — do not edit files. Cite file:line for any issues.
