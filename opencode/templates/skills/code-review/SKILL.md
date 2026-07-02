---
name: code-review
description: Review code changes for bugs, security issues, performance problems, and code quality. Checklist-driven review without making edits.
license: MIT
compatibility: opencode
metadata:
  audience: developers
---

## What I do
- Review code changes for correctness
- Identify potential bugs and edge cases
- Check for security vulnerabilities
- Spot performance issues
- Verify code style and conventions
- Check test coverage
- Suggest improvements without making changes

## When to use me
Use this skill when:
- Reviewing pull requests or git diffs
- Checking recent changes before commit
- Auditing code quality in a specific file or module
- Verifying that acceptance criteria are met in the code

## Review checklist
1. **Correctness** — Does the code do what it claims to do?
2. **Edge cases** — Null/undefined, empty arrays, boundary values
3. **Security** — Input validation, SQL injection, XSS, exposed secrets
4. **Performance** — N+1 queries, unnecessary re-renders, memory leaks
5. **Error handling** — Try/catch, error boundaries, fallback states
6. **Testing** — Unit tests for new logic, integration tests for flows
7. **Code style** — Consistent naming, proper types, no dead code
8. **Dependencies** — No unused imports, pinned versions, security advisories

## Workflow
```bash
# See what changed
git diff HEAD~1 --stat

# Review specific changes
git diff HEAD~1 -- <path>

# Check for secrets accidentally committed
git diff HEAD~1 | grep -iE '(password|secret|token|key|api_key)'

# Run lint on changed files
git diff HEAD~1 --name-only | grep -E '\.(ts|tsx|js|jsx)$' | xargs npx eslint

# Run typecheck
npx tsc --noEmit
```

## Output format
```
## Code Review: <branch/PR>

### Issues Found
- [CRITICAL] <file>:<line> — <issue description>
- [WARNING] <file>:<line> — <issue description>
- [INFO] <file>:<line> — <suggestion>

### Summary
- Critical: X, Warnings: Y, Info: Z
- Overall: APPROVED / CHANGES REQUESTED
```
