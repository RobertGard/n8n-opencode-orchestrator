---
name: test-workflow
description: Run test suites, analyze failures, check coverage, and fix failing tests. Complete testing workflow from execution to remediation.
license: MIT
compatibility: opencode
metadata:
  audience: developers
---

## What I do
- Run project test suites (unit, integration, e2e)
- Analyze test failures and identify root causes
- Check test coverage against thresholds
- Suggest fixes for failing tests
- Verify that new code is properly tested
- Run tests in watch mode for rapid iteration

## When to use me
Use this skill when:
- Verifying code changes pass all tests
- Analyzing why a test is failing
- Checking if test coverage meets requirements
- Adding tests for new functionality
- Running a specific subset of tests

## Commands reference
```bash
# Run all tests
npm test
# or: pytest, cargo test, go test, etc.

# Run specific test file
npm test -- --testPathPattern=<file>

# Run tests with coverage
npm test -- --coverage

# Run tests in watch mode
npm test -- --watch

# Run only failing tests from last run
npm test -- --onlyFailures

# TypeScript typecheck
npx tsc --noEmit

# Lint check
npm run lint
```

## Workflow
1. Identify the test command from package.json, Makefile, or project config
2. Run the full test suite: note pass/fail counts
3. If tests fail:
   a. Read the failing test file
   b. Identify if the failure is in the test or the implementation
   c. For test failures: explain why. For implementation failures: suggest fix
4. Check coverage: is new code covered?
5. Run lint and typecheck as sanity gates
6. Report all results with evidence

## Output format
```
## Test Results
- Total: X, Passed: Y, Failed: Z
- Coverage: XX% (threshold: YY%)

### Failing Tests
- <test name>: <failure reason>
- <test name>: <failure reason>

### Recommendations
- <specific action to fix each failure>
```
