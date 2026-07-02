# OpenCode Global Rules

## General behavior
- Be concise. Prefer actions over explanations.
- When making changes, follow existing code conventions exactly.
- Never read .env files unless explicitly asked.
- Never expose secrets, tokens, or API keys in output.
- Prefer using available MCP tools (filesystem, github, playwright, context7, brave-search, memory) over raw bash when appropriate.
- After making changes, verify with lint, typecheck, and tests.
- When in doubt, ask clarifying questions rather than assuming.

## Docker access
- Docker socket is mounted and available. Use `docker compose` for service management.
- Always check container logs when troubleshooting.
- After code changes that affect running services, rebuild and restart affected containers.

## Available commands
- `/verify` — Run verification checks
- `/docker-up` — Start Docker services
- `/repair` — Repair common issues
- `/bootstrap-repo` — Initialize repository setup

## Available skills
- `browser-test` — Test web apps with Playwright (use when criteria mention URLs/browser)
- `docker-manage` — Manage Docker containers and check logs
- `code-review` — Review code for bugs and quality (use before committing)
- `test-workflow` — Run and analyze test suites
- `ast-grep` — AST-aware code search and rewriting (use instead of grep for code)
- `git-master` — Atomic commits, surgical rebases, bisect debugging
- `review-work` — Post-implementation review against plan
- `remove-ai-slops` — Clean AI-generated code smells from recent changes
- `frontend` — Design-first UI with a11y, responsive, state handling
- `api-testing` — Test REST + GraphQL endpoints
- `security-audit` — OWASP Top 10 + CVE scan + secret detection
- `dependency-audit` — CVE/vuln/outdated/license check
- `performance-profile` — CPU/memory/N+1/bundle analysis
- `deployment-verify` — Pre/deploy/post verification + rollback
- `schema-migration` — Database migration review and safety checks

## Documentation references
When working with these technologies, use `webfetch` or `context7` to access:
- **Node.js API**: https://nodejs.org/docs/latest/api/
- **React**: https://react.dev/reference/react
- **TypeScript**: https://www.typescriptlang.org/docs/handbook/
- **MDN Web Docs**: https://developer.mozilla.org/en-US/docs/Web
- **Docker**: https://docs.docker.com/reference/
- **Prisma**: https://www.prisma.io/docs/orm/reference

## Project conventions
- Workspace root is at /workspace
- Configuration is at /workspace-config
- Docker compose project is defined at the workspace root
