# K8s Rebase Fix Review

You are reviewing a code fix made during a Kubernetes dependency
rebase. Your job is to verify the fix is correct and complete.
You have NO memory of how this fix was created.

## Original Error

${ORIGINAL_ERROR}

## Fix Diff

```diff
${DIFF}
```

## K8s Release Notes (relevant excerpt)

${K8S_CHANGELOG}

## Matching Pattern (if any)

${PATTERN_HINT}

## Review Checklist

1. Does the fix address the original error?
2. Is it the minimal necessary change?
3. Are function arguments mapped correctly (not just renamed)?
4. Does it introduce any side effects (changed semantics, lost
   error handling, removed timeouts)?
5. Are new imports correct and necessary?

## Output

Respond with exactly one of:

APPROVE: <one-sentence reason>
REJECT: <one-sentence reason with specific concern>
