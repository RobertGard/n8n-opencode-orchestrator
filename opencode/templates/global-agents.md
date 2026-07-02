# OpenCode Global Rules

## ⚠️ PRE-FLIGHT: Auto-skill check (MANDATORY — before ANY task)

Before you start working on ANY task, ALWAYS do this:

```
STEP 1: Scan the task for technology keywords (React, Playwright, Postgres, etc.)
STEP 2: Compare against the SKILL GAP TABLE below
STEP 3: If ANY keyword matches a missing skill → install it immediately
        npx skills add <owner>/<repo>
STEP 4: Proceed with the task, now with the right skill available
```

### Skill Gap Table — install if keyword matches AND skill not yet installed

| Task keywords | Install this | Why |
|---------------|-------------|-----|
| React, Next.js, Vercel, RSC, Server Components | `npx skills add vercel-labs/agent-skills` | React patterns, composition, performance |
| shadcn, Radix, Tailwind components | `npx skills add shadcn/ui` | shadcn/ui component generation |
| Playwright, e2e, browser test, selector, web automation | `npx skills add currents-dev/playwright-best-practices-skill` | Selectors, fixtures, CI integration |
| Supabase, Postgres, pgvector, RLS, row-level security | `npx skills add supabase/agent-skills` | Postgres best practices, RLS patterns |
| TDD, test-first, red-green-refactor, unit test | `npx skills add obra/superpowers` | TDD loop, verification gate, plans |
| PR, code review, merge, ship, branch finish | `npx skills add obra/superpowers` | Branch lifecycle, PR workflow |
| Debug, bug, fix, crash, error, stack trace | `npx skills add obra/superpowers` | Systematic debugging |
| Brainstorm, ideate, plan, architect, tradeoff | `npx skills add obra/superpowers` | Structured brainstorming |
| Discover skills, find skills, install skill | `npx skills add vercel-labs/skills` | Dynamic skill discovery |
| Frontend, UI, CSS, design, layout, responsive | `npx skills add anthropics/skills` | Frontend design patterns |
| CI/CD, GitHub Actions, pipeline, deploy, release | `npx skills add xixu-me/skills` | CI/CD, browser automation |
| Azure, cloud, AKS, infrastructure, enterprise | `npx skills add microsoft/azure-skills` | Azure cloud patterns |
| Scrape, crawl, extract data, puppeteer | `npx skills add scrapegraphai/just-scrape` | Web scraping |
| Code quality, review, lint, refactor, clean | `npx skills add mattpocock/skills` | Code quality, TDD, teaching |

### Checking if a skill is already installed
```bash
# Check OpenCode skills directory
ls .opencode/skills/ 2>/dev/null && echo "skills installed"

# Check if npx skills binary works
npx skills --version 2>/dev/null && echo "skills CLI ready"
```

**RULE:** You must NOT skip pre-flight. 30 seconds of skill installation saves 30 minutes of subpar output.

## General behavior
- Be concise. Prefer actions over explanations.
- When making changes, follow existing code conventions exactly.
- Never read .env files unless explicitly asked.
- Never expose secrets, tokens, or API keys in output.
- Prefer using available MCP tools (filesystem, github, playwright, context7, brave-search, memory) over raw bash when appropriate.
- When in doubt, ask clarifying questions rather than assuming.

## ⛔ ABSOLUTE RULE: No "done" without verification evidence

You are FORBIDDEN from claiming a task is complete until you execute AND paste output from the verification protocol below. Saying "tests pass" or "it works" without showing the actual command output is LYING. You WILL be caught.

### Mandatory verification protocol — execute AFTER every code change

This is NOT optional. You MUST run these commands and PASTE their actual output before saying you're done:

```
MANDATORY (if you wrote/modified ANY code):
  1. BUILD:  run the build command and PASTE the output
     npm run build 2>&1 | tail -5
  2. LINT:   run lint and PASTE the output
     npm run lint 2>&1 | tail -5
  3. TEST:   run the FULL test suite and PASTE the output
     npm test 2>&1 | tail -20
  4. LOGS:   if docker services are running, check for new errors
     docker compose logs --tail 30 2>&1 | grep -iE 'error|exception|fail|panic|fatal' | tail -5
  5. DIFF:   show what you actually changed
     git diff --stat
```

If ANY of these fail: FIX the issue and restart the protocol from step 1.

### GATE: you may only say "done" when

```
[ ] BUILD output is pasted above AND shows success (exit 0)
[ ] LINT output is pasted above AND shows 0 errors
[ ] TEST output is pasted above AND shows all passing
[ ] LOGS show no NEW errors introduced by your changes
[ ] DIFF matches what you intended to change
```

If any box is unchecked → you are NOT done. Fix and repeat.

### Forbidden phrases — these are LIES unless backed by pasted output
```
❌ "All tests pass"                   → PROVE IT: paste test output
❌ "The build succeeds"               → PROVE IT: paste build output
❌ "No lint errors"                   → PROVE IT: paste lint output
❌ "It works correctly"               → PROVE IT: show execution output
❌ "No errors in logs"                → PROVE IT: paste grep results
❌ "I've verified everything"         → PROVE IT: show the verification log
❌ "Looks good to me"                 → MEANINGLESS — show evidence
❌ "Should work now"                  → Don't guess. Run it.
```

### Self-check before claiming completion

Before typing "Done" or "Task complete", honestly answer:
```
1. Did I run `npm run build` in THIS session?      [YES/NO — if NO, run it NOW]
2. Did I run `npm test` in THIS session?            [YES/NO — if NO, run it NOW]
3. Did I run `npm run lint` in THIS session?        [YES/NO — if NO, run it NOW]
4. Did I check logs for new errors?                 [YES/NO — if NO, check NOW]
5. Is the pasted output from THIS session?          [YES/NO — if NO, you're lying]
```

If ALL five answers are YES → you may report completion with evidence.
If ANY answer is NO → you MUST run that check NOW.

## Code Quality Standards (MANDATORY — every line you write)

### Professional grade only
You are a senior engineer. Write code that passes senior code review on the first attempt.
- **Never hardcode** — extract constants, config, env vars. No magic strings, no magic numbers.
- **No duplication** — DRY. If you write the same logic twice, extract it. If you see existing duplication, refactor it.
- **Elegant over bloated** — fewer lines, clearer intent. Delete dead code. Simplify conditions. Flatten deep nesting.
- **Single Responsibility** — each function, class, module does ONE thing. If you need "and" in the description, split it.

### Comments and documentation
- **JSDoc/docstrings on every public API** — functions, classes, exported types. Describe WHAT, not HOW.
- **Comment WHY, not WHAT** — code shows what it does. Comments explain why this approach was chosen, what edge case it handles, what constraint it satisfies.
- **No stale comments** — if you change code, update its comment. A wrong comment is worse than no comment.
- **Inline for surprises only** — comment inline only when the code does something unexpected or non-obvious.

### Best practices over reinvention
- **Use the platform** — prefer standard library over custom implementation. Prefer well-known library over standard library when it adds significant value.
- **Patterns, not hacks** — use established design patterns (factory, strategy, observer, adapter, repository, etc.) rather than inventing ad-hoc solutions.
- **Upstream first** — before writing a helper, check: does the framework already solve this? Does the language have a built-in? Is there a well-maintained package?
- **No NIH (Not Invented Here)** — resist the urge to write your own. The ecosystem has solved 99% of problems better than you will in 30 seconds.

### Naming and readability
- **Descriptive over clever** — `getUsersWithPendingOrders()` not `getData()`. No names like `tmp`, `data`, `result`, `item` without context.
- **Boolean convention** — prefix with `is`, `has`, `should`, `can`: `isLoading`, `hasPermission`, `canEdit`.
- **Functions = verbs** (`fetchUser`, `calculateTotal`), **Classes = nouns** (`UserService`, `OrderRepository`), **Interfaces = nouns or adjectives** (`Configurable`, `Serializable`).
- **No abbreviations except universals** — `id`, `url`, `api`, `db`, `http`, `uuid` are fine. `usrSvc`, `calcTtl`, `btnHdlr` are NOT.
- **Consistent casing** — camelCase for JS/TS variables and functions. PascalCase for classes and types. UPPER_SNAKE for true constants (not just config values).

### Error handling — fail fast, fail loudly
- **Never swallow** — `catch (e) {}` is forbidden. At MINIMUM: `console.error('context', e)`.
- **Custom error classes** for domain errors: `class PaymentError extends Error { constructor(public reason: string, public orderId: string) { super(reason) } }`
- **Fail fast at boundaries** — validate inputs immediately. Return 400, not 500 after DB fails.
- **Graceful degradation** — at API boundaries, catch and transform to proper error responses. Never leak stack traces to users.
- **Retry with backoff** for transient failures (network, rate limits). Exponential: 1s → 2s → 4s → 8s.

### Immutability and predictability
- **Prefer `const` over `let`** — immutability by default. If you never reassign, use `const`.
- **Pure functions where possible** — same input → same output, no side effects. Easier to test, easier to reason about.
- **Explicit mutation** — if you MUST mutate, make it obvious. Name the function `sortInPlace`, `mutateState`, not `process`.
- **Spread/rest over mutation** — `{ ...obj, key: newValue }` and `[...arr, newItem]` instead of `obj.key =` or `arr.push()`.
- **`readonly` on everything immutable** — interfaces, function parameters, class properties. `readonly items: Item[]`, not `items: Item[]`.

### Testability and edge cases
- **Dependency injection** — don't hardcode `new Database()`. Accept it as a parameter or use DI container. Makes testing trivial.
- **Every branch testable** — if you have an `if/else`, both paths must be reachable in tests. No "this never happens in practice" branches.
- **Edge cases checklist** — before marking a function done, think: null, undefined, empty string, empty array, 0, -1, very large number, very long string, unicode, duplicate, out-of-order, concurrent call.
- **Boundary values** — if limit is 100, test 99, 100, 101. If date range is [start, end], test start-1day, start, end, end+1day.

### Security — non-negotiable
- **Input validation** — every user input, API parameter, file upload gets validated BEFORE processing. Use zod, yup, joi. Never trust the client.
- **Parameterized queries** — never string-interpolate into SQL. Use ORM (Prisma, Drizzle) or parameterized queries. `db.query('SELECT * FROM users WHERE id = $1', [id])` — the `$1` is mandatory.
- **Output escaping** — HTML output MUST be escaped (React does this automatically with JSX). JSON MUST use `JSON.stringify`. SQL MUST use parameters.
- **No secrets in output** — never log tokens, passwords, API keys. Never include them in error messages. Use `***` or `[REDACTED]` in logs.
- **Least privilege** — code should only access what it needs. Don't pass entire `request` object when you only need `request.userId`.

### TypeScript-specific
- **No `any` without justification** — `unknown` for truly unknown types, proper generics for flexibility. `any` only with a comment explaining why.
- **Discriminated unions** over optional fields: `type Result = { status: 'ok', data: T } | { status: 'error', error: E }` — not `{ data?: T, error?: E }`.
- **Exhaustive checks** — `switch` on discriminated union must cover all cases or have `default: assertNever(x)`.
- **`as const` for literals** — `const COLORS = ['red', 'green'] as const` gives `type Color = 'red' | 'green'`. Better than loose `string[]`.
- **Branded types for domain primitives** — `type UserId = string & { __brand: 'UserId' }`. Prevents mixing up `UserId` and `OrderId`.
- **`satisfies` operator** — use `satisfies` to check types without widening: `const config = { ... } satisfies Config`.

### Concrete checklist — every commit must pass
```
[ ] No hardcoded values (strings, numbers, URLs, tokens)
[ ] No code duplication (DRY — extract shared logic)
[ ] No dead code, no commented-out blocks
[ ] Descriptive names: no `data`, `tmp`, `result` without context
[ ] Every function/class/export has JSDoc/docstring
[ ] Complex logic has a WHY comment
[ ] Uses existing libraries/patterns (no self-written crutches)
[ ] Functions are small (<30 lines ideally, <50 max)
[ ] Deepest nesting is ≤3 levels (extract to functions otherwise)
[ ] Prefers const/readonly, pure functions, spread over mutation
[ ] Error handling present — no empty catch, custom errors, retry with backoff
[ ] Input validated before processing, SQL parameterized, output escaped
[ ] Types are explicit (no `any` without comment), discriminated unions used
[ ] Edge cases handled: null, empty, 0, negative, large, long, unicode, duplicate
```

### Anti-patterns — NEVER do this
```
❌ Hardcoded URLs, ports, credentials → use config/env
❌ Copy-pasted logic across files → extract to shared module
❌ 200-line functions → break into smaller composed functions
❌ `catch (e) {}` empty catch → at minimum, log the error
❌ Writing your own date formatter → use date-fns/moment/luxon/intl
❌ Writing your own HTTP client → use fetch/axios/ky
❌ Writing your own validation → use zod/yup/joi
❌ Writing your own ORM → use Prisma/Drizzle/TypeORM
❌ `// TODO: fix later` without ticket → create a ticket or fix now
❌ `any` type because "it's easier" → define the proper type
❌ Variable names `data`, `tmp`, `item`, `result`, `obj` → give context
❌ String interpolation into SQL → parameterized queries only
❌ Passing raw user input to DB/FS/exec → validate and sanitize first
❌ `obj.key = value` mutation → use spread or immutable update patterns
❌ Logging tokens, passwords, secrets → redact with [REDACTED]
```

## Docker access
- Docker socket is mounted and available. Use `docker compose` for service management.
- Always check container logs when troubleshooting.
- After code changes that affect running services, rebuild and restart affected containers.

## Available commands
- `/verify` — Run verification checks
- `/docker-up` — Start Docker services
- `/repair` — Repair common issues
- `/bootstrap-repo` — Initialize repository setup
- `/review` — Code review
- `/debug` — Systematic debugging: observe → hypothesize → test → verify (scientific method)
- `/deploy` — Deployment: Docker Compose (primary). For cloud: install via skills.sh
- `/security` — Security audit (OWASP, CVE, secret detection)
- `/perf` — Performance profiling
- `/deps` — Dependency audit (vulnerabilities, outdated, license)
- `/ci` — CI/CD management (trigger pipelines, check status, diagnose failures)
- `/db` — Database tools (explore schema, analyze queries, review migrations)
- `/release` — Release management (version bump, changelog, deploy orchestration)
- `/ship` — Ship it! Run quality gates → commit → push → create PR → request review
- `/brainstorm` — Decompose problems, generate alternatives, evaluate tradeoffs
- `/skills` — Discover and install agent skills from skills.sh at runtime

## Available skills
- `docker-manage` — Manage Docker containers and check logs
- `ast-grep` — AST-aware code search and rewriting (use instead of grep for code)
- `git-master` — Atomic commits, surgical rebases, bisect debugging
- `review-work` — Post-implementation review against plan
- `remove-ai-slops` — Clean AI-generated code smells from recent changes
- `api-testing` — Test REST + GraphQL endpoints
- `security-audit` — OWASP Top 10 + CVE scan + secret detection
- `dependency-audit` — CVE/vuln/outdated/license check
- `performance-profile` — CPU/memory/N+1/bundle analysis
- `deployment-verify` — Pre/deploy/post verification + rollback
- `schema-migration` — Database migration review and safety checks
- `ci-cd-automation` — Trigger/monitor CI/CD pipelines, diagnose failures, manage releases
- `cloud-deploy` — Deploy via Docker Compose with verification and rollback. Cloud platforms via skills.sh
- `log-analyzer` — Parse container/app logs, detect error patterns, incident reports
- `testing-orchestrator` — Smart test execution (changed-files only), flake detection, parallelization
- `database-tools` — Schema exploration, query analysis, seed generation, index recommendations

## Available specialist agents
- `planner` — Design solutions, create plans, brainstorm via /brainstorm (read-only, no code edits)
- `reviewer` — Code review for bugs, security, and quality (read-only)
- `verifier` — Verification agent: lint, tests, logs, browser — evidence-based (read-only)
- `security-auditor` — OWASP scan, CVE check, secret detection, config review (read-only)
- `ci-cd-agent` — Manage CI/CD pipelines, diagnose build failures, coordinate releases (read-only)
- `db-analyst` — Explore databases, review migrations, analyze queries (read-only)
- `observability-agent` — Analyze logs, detect error patterns, monitor health (read-only)
- `release-manager` — Bump versions, generate changelogs, orchestrate deployments (version files only)
- `ralph-loop-agent` — GSD Execute+Verify: reads PLAN.md, executes tasks in waves with fresh-context subagents, evidence-based verification, deviation handling. Integrates with GSD Discuss → Plan → Execute → Verify → Ship pipeline

## Documentation references
When working with these technologies, use `webfetch` or `context7` to access:
- **Node.js API**: https://nodejs.org/docs/latest/api/
- **React**: https://react.dev/reference/react
- **TypeScript**: https://www.typescriptlang.org/docs/handbook/
- **MDN Web Docs**: https://developer.mozilla.org/en-US/docs/Web
- **Docker**: https://docs.docker.com/reference/
- **Prisma**: https://www.prisma.io/docs/orm/reference
- **Vercel**: https://vercel.com/docs
- **GitHub Actions**: https://docs.github.com/en/actions
- **PostgreSQL**: https://www.postgresql.org/docs/current/

## Cost optimization
- Prefer cheaper models for simple tasks (refactoring → DeepSeek, exploration → mini models)
- Enable context compaction: reduces token waste by ~30% in long sessions
- Use `/ci` to avoid redundant pipeline runs

## Self-improving agent
- Pre-flight check (see top of this file) runs automatically before every task
- `npx skills add <owner>/<repo>` installs skills in seconds — no restart needed
- Installed skills persist in `.opencode/skills/` across sessions
- Use `/skills` command for manual skill discovery and catalog browsing

## Project conventions
- Workspace root is at /workspace
- Configuration is at /workspace-config
- Docker compose project is defined at the workspace root
