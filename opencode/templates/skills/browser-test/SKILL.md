---
name: browser-test
description: Test web applications in a real browser using Playwright MCP. Navigate, fill forms, verify UI, capture console and network logs.
license: MIT
compatibility: opencode
metadata:
  audience: developers
  requires: playwright-mcp
---

## What I do
- Navigate to URLs and verify page content
- Fill forms, click buttons, submit data
- Capture browser CONSOLE LOGS (errors, warnings, console.error)
- Capture NETWORK errors (failed requests, 4xx, 5xx)
- Take screenshots at verification points
- Verify expected UI elements appear/disappear
- Test responsive layouts at different viewport sizes

## When to use me
Use this skill when acceptance criteria mention:
- A website, URL, or web application
- UI verification ("check the page shows...")
- Form interactions ("fill in the form and submit")
- Browser console checks ("no console errors")
- Visual regression testing

## How to use Playwright MCP
The Playwright MCP server is pre-configured. Use these tools:
- `playwright_navigate` — go to a URL
- `playwright_click` — click an element
- `playwright_fill` — type into a field
- `playwright_screenshot` — capture the page
- `playwright_evaluate` — run JavaScript (e.g., check console logs)

## Workflow
1. Ensure the project is running (`docker compose up -d` or equivalent)
2. Navigate to the target URL
3. Perform all user actions described in the test
4. After each action, verify the expected result
5. Capture console logs: `playwright_evaluate` with `() => window.__consoleErrors || []`
6. Check network tab for failed requests
7. After testing, re-check docker logs for new errors
8. Report all findings with evidence (URLs, screenshots, log output)

## Common patterns
```
# Check if app is running
curl -s http://localhost:3000 | head -20

# Navigate
playwright_navigate({ url: "http://localhost:3000" })

# Fill form
playwright_fill({ selector: "#email", value: "test@example.com" })
playwright_fill({ selector: "#password", value: "password123" })

# Submit
playwright_click({ selector: "button[type=submit]" })

# Verify
playwright_screenshot({ name: "after-login" })
```
