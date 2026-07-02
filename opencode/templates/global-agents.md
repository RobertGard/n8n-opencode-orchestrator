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

## Project conventions
- Workspace root is at /workspace
- Configuration is at /workspace-config
- Docker compose project is defined at the workspace root
