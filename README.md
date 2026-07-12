# OpenCode + n8n

Self-hosted AI development assistant: submit a task in Telegram or by voice (Home Assistant), n8n dispatches it to OpenCode workers, results come back to the chat or read aloud via TTS.

> **Русская версия:** [README.ru.md](./README.ru.md)

**Key features:**

- **Multi-Worker** — any number of workers, each with its own project and MCP toolset
- **Session context** — workers remember conversation history, you can refine and extend tasks within a session
- **Interactive OpenCode** — workers can ask clarifying questions directly in chat; you answer, they continue
- **Auto-mode** — after task completion, the bot analyzes results and suggests the next step: GSD cycle, quality checks, tests, documentation
- **Task chains** — a task can wait for its parent to complete and execute only if the result contains specified text (e.g. tests passed → deploy)
- **Acceptance verification** — pass `--verify="criteria"` with a task; after completion, a verification task is queued for the agent (in a fresh session, independent of the original). The agent checks code health, logs, browser console (Playwright), API responses, and per-criterion evidence. Result goes to DeepSeek Judge — on FAILED, a fix task is auto-created with the original session and criteria
- **Recurring tasks** — `--interval="4h"` flag runs a task on a schedule (30m, 4h, 1d). Stops with `/abort`. Saves DB space — reuses the same row
- **Natural language commands** — type requests in plain language; an AI translator converts them to structured commands with proper flags
- **OpenCode slash commands** — use `/gsd-ship`, `/deploy`, `/brainstorm` etc. in Telegram — they're automatically wrapped as `/task --prompt="/command"` for the worker
- **Fully self-hosted** — no cloud services, all data under your control
- **Batteries included** — PostgreSQL, Redis, n8n, Home Assistant, Caddy (HTTPS) — one `bash setup-stack.sh` and you're ready
- **Voice control** — Home Assistant + Companion App on your phone. Wake word "Окей, Ассистент" → voice task → TTS result back to phone. Works alongside Telegram
- **CI/CD integration** — trigger pipelines, check build status, diagnose failures, manage releases (`/ci`, `/release`)
- **Database tools** — explore schemas, analyze queries, review migrations, generate seed data (`/db`)
- **Observability** — log analysis, error pattern detection, incident reports, health monitoring
- **Docker deployment** — deploy, verify health, check logs, rollback via `/deploy`
- **9 specialist subagents + 2 primary agents (build, plan)** — planner, reviewer, verifier, security-auditor, ci-cd-agent, db-analyst, observability-agent, release-manager, ralph-loop-agent (GSD Execute+Verify)
- **16 built-in skills** — from code review and performance profiling to CI/CD automation and Docker deployment
- **skills.sh integration** — agents auto-discover and install skills from skills.sh via pre-flight check
- **Code quality enforcement** — mandatory verification gate, anti-hardcoding rules, professional-grade standards
- **Worker resource limits** — configurable CPU/memory caps per worker (`4GB/2CPU` default)

## Requirements

- Docker Engine + Docker Compose
- Telegram bot token (for Telegram mode)
- Public domain, ports 80/443 (for HTTPS)

## Quick start

```bash
bash ./scripts/setup-stack.sh
```

The script asks questions, creates `.env` and `config.json`, launches containers, configures Telegram.

### Reinstall

```bash
docker compose down -v --rmi all --remove-orphans
docker builder prune -af
bash ./scripts/setup-stack.sh
```

## Telegram bot commands

The bot accepts commands via `/`. Flags use `--flag="value"` format.

System commands (handled by the bot directly):

### `/task` — task creation and management

| Command | Description |
|---|---|
| `/task --prompt="description"` | Create a new task |
| `/task --answer="answer"` | Answer an OpenCode question (auto-selects pending task) |
| `/task --task_key="xxx" --answer="answer"` | Answer a specific pending task |
| `/task --parent_task_key="xxx" --parent_match_text="text"` | Follow-up with text match check in parent result |
| `/task --auto_mode="true"` | Enable auto-mode |
| `/task --auto_mode="false"` | Disable auto-mode |

### `/abort` — task cancellation

| Command | Description |
|---|---|
| `/abort --task_key="xxx"` | Abort a specific task (running or queued recurring) |
| `/abort` | Auto-select the only running task |

### Additional flags

| Flag | Description |
|---|---|
| `--worker="alias"` | Assign task to a specific worker |
| `--new_session` / `--fresh_session` | Force a new OpenCode session |
| `--verify="criteria"` | Acceptance criteria — after task completion, a verification task is queued (fresh session). The agent checks code health, logs, browser (Playwright), API responses. DeepSeek Judge evaluates the result; on FAILED auto-creates a fix task with the original session and criteria |
| `--interval="4h"` | Recurring task — re-executes every N hours/days. Format: number + m/h/d (30m, 4h, 1d). Cancel with `/abort --task_key="xxx"` |

### OpenCode worker commands

All other `/` commands (like `/gsd-ship`, `/deploy`, `/brainstorm`) are automatically wrapped as `/task --prompt="/command"` and sent to the worker. The worker executes them as OpenCode slash commands. This includes:

| Command | Where it runs | Description |
|---------|-------------|-------------|
| `/ci` | Worker (OpenCode) | CI/CD management |
| `/db` | Worker (OpenCode) | Database tools |
| `/release` | Worker (OpenCode) | Release management |
| `/ship` | Worker (OpenCode) | Quality gates → commit → push → PR |
| `/deploy` | Worker (OpenCode) | Docker deployment |
| `/brainstorm` | Worker (OpenCode) | Problem decomposition |
| `/skills` | Worker (OpenCode) | Skills discovery from skills.sh |
| `/gsd-*` | Worker (OpenCode) | GSD workflow commands |

### Answering OpenCode questions

OpenCode asks a question → the bot sends numbered options.

- **Single question** — option number or label text
- **Multiple questions** — separated by `||`: `1 || Prisma`
- **Multi-select** — separated by `&&`: `1 && 3`
- **Reject** — `/reject` or `/task --answer="/reject"`

### Auto-mode

`/task --auto_mode="true"` — after each completed task, the bot suggests the next: GSD cycle, quality checks, tests, documentation. Auto-tasks (prefix `auto-`) inherit the worker from the triggering task.

### Natural language translation

You don't have to write structured commands. Just type in plain language:

| Input | Translated to |
|---|---|
| `deploy the project` | `/task --prompt="deploy the project"` |
| `run fixes on the second worker` | `/task --prompt="run fixes" --worker="worker-2"` |
| `answer 2 in task task-abc` | `/task --task_key="task-abc" --answer="2"` |
| `if task task-abc result contains "done" then run cleanup` | `/task --parent_task_key="task-abc" --parent_match_text="done" --prompt="run cleanup"` |
| `enable automode` | `/task --auto_mode="true"` |
| `cancel task task-xyz` | `/abort --task_key="task-xyz"` |
| `refactor the code. verify that lint passes and tests are green` | `/task --prompt="refactor the code" --verify="lint passes and tests are green"` |
| `run refactoring every 4 hours` | `/task --prompt="run refactoring" --interval="4h"` |
| `/gsd-ship` | `/task --prompt="/gsd-ship"` (worker command, wrapped) |
| `/task --prompt="already a command"` | `/task --prompt="already a command"` (system command, passes through) |

The translator is an AI Agent (DeepSeek) that runs before the command parser. System commands (`/task`, `/abort`) pass through unchanged. All other slash commands are wrapped for the worker.

### Recurring tasks

Use `--interval="4h"` to create a task that re-executes on a schedule:

1. Task completes → status resets to `queued` with `queued_at = now + interval`
2. Dispatcher respects future `queued_at` — task won't execute before the interval
3. Same DB row, no clones, no data bloat
4. Cancel with `/abort --task_key="xxx"` — sets status to `aborted`, cycle stops
5. Format: `30m` (minutes), `4h` (hours), `1d` (days)

### Acceptance verification pipeline

When you include `--verify="criteria"` with a task:

1. OpenCode completes the primary task
2. The verifier workflow creates a **verification task** in the queue (fresh session, independent of the original)
3. The agent executes the verification — checking code health, logs, browser console (Playwright), API responses, and each criterion against evidence
4. Verification task completes → verifier is triggered again
5. A **DeepSeek AI judge** evaluates the verification result and returns a PASSED/FAILED verdict
6. If FAILED → a **fix task** is auto-created with the **original session** and same `--verify` criteria
7. Fix task → verify → fix → ... cycle repeats until verification passes
8. If PASSED → notification sent, no further tasks

## Architecture

```
Telegram / Voice (HA) → n8n ingress → Data Table → n8n dispatcher → OpenCode worker → result in Telegram + TTS
```

**Services:** `postgres`, `redis`, `n8n`, `n8n-worker`, `opencode-worker-1`, `homeassistant`, `caddy` (optional)

**n8n Workflows (8):** ingress, dispatcher, session-manager, task-launcher, pending-interaction, task-finalizer, auto-task-generator, acceptance-verifier

## Specialist agents

9 specialized subagents + 2 primary agents (build, plan), each with role-based permissions:

| Agent | Role | Permissions |
|-------|------|-------------|
| `build` | General-purpose coder | Full read/write/bash |
| `planner` | Design & architecture | Read-only, webfetch allowed |
| `reviewer` | Code review | Read-only, no edits |
| `verifier` | Acceptance verification | Read-only, bash allowed |
| `security-auditor` | OWASP + CVE scan | Read-only, limited bash |
| `ci-cd-agent` | Pipeline management | Read-only, `gh` CLI allowed |
| `db-analyst` | Database analysis | Read-only, DB introspection |
| `observability-agent` | Log analysis & monitoring | Read-only, log inspection |
| `release-manager` | Versioning & deployment | Version files only |
| `ralph-loop-agent` | GSD Execute+Verify | Full read/write, subagent orchestration |

## Worker configuration

Workers are configured via `workers/config.json.default` — the single source of truth. Per-worker directories are generated by the setup script on deployment.

```json
{
  "repos": [{
    "slug": "my-project",
    "url": "https://github.com/user/my-project.git",
    "ref": "main",
    "path": "my-project"
  }],
  "tooling": { ... }
}
```

**Repo fields:** `slug`, `url`, `ref`, `path`, `package_manager` (default `auto`), `turbo_smoke` (`false`), `turbo_tasks` (`["build","test"]`), `auto_start_docker` (`true`).

**tooling** — global packages and MCP servers. Structure: `npm` (npm install -g), `uv` (uv tool install), `post_install` (commands after install).

**Worker resource limits:** configurable via `.env`:
```bash
OPENCODE_WORKER_CPU_LIMIT=2      # CPU cores per worker
OPENCODE_WORKER_MEMORY_LIMIT=4g  # RAM per worker
```

## Environment variables (.env)

Created from `.env.example`. Key sections:

| Group | Variables |
|---|---|
| n8n | `N8N_HOST`, `N8N_VERSION`, `N8N_PROTOCOL`, `N8N_PORT`, `N8N_ENCRYPTION_KEY`, `N8N_BASIC_AUTH_*`, `N8N_API_KEY` |
| Database | `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD` |
| Worker N | `OPENCODE_WORKER_N_NAME`, `_ALIAS`, `_PORT`, `_PASSWORD`, `_BASE_URL`, `_HEALTH_URL` |
| Worker limits | `OPENCODE_WORKER_CPU_LIMIT`, `OPENCODE_WORKER_MEMORY_LIMIT` |
| API keys | `OPENAI_API_KEY`, `DEEPSEEK_API_KEY`, `ANTHROPIC_API_KEY`, `OPENROUTER_API_KEY`, `GITHUB_TOKEN` |
| Telegram | `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_IDS` |
| Home Assistant | `HA_API_TOKEN`, `HA_NOTIFY_SERVICE`, `HA_PIPELINE_LANGUAGE`, `HA_HOST` |
| OpenCode | `OPENCODE_AGENT`, `OPENCODE_MODEL`, `OPENCODE_PROVIDER_TIMEOUT_MS` |
| Optional | `DATABASE_URL`, `GITHUB_REPOSITORY`, `BRAVE_API_KEY` |

## Operations

```bash
# Stack health check
bash ./scripts/verify-stack.sh

# Launch with HTTPS
docker compose --profile proxy up -d --build

# Additional workers
docker compose -f docker-compose.yml -f compose.overrides/opencode-worker-2.yml up -d --build

# Execution cleanup (automated via cron)
bash ./scripts/cleanup-executions.sh
```

## Telegram: first launch

1. `bash ./scripts/setup-stack.sh` → provide `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_IDS`
2. Open n8n → Settings → n8n API → create an API key
3. Add to `.env`: `N8N_API_KEY=<key>`
4. `bash ./scripts/bootstrap-telegram-integration.sh`

After `docker compose down -v`, the script detects an expired key and asks for a new one.

## Voice control (Home Assistant)

Included in the stack automatically. Wyoming Whisper + Piper for local STT/TTS (~300MB RAM, no GPU needed). **Fully automated — zero UI clicks:**

1. `bash ./scripts/setup-stack.sh` starts HA + Wyoming containers on port 8123
2. Open HA in browser, create user, go to Profile → Security → Long-lived access tokens → create token
3. Install HA Companion App on phone, connect to HA URL
4. `bash ./scripts/bootstrap-telegram-integration.sh` — **automatically handles everything else**:
   - Prompts for HA token (if not set in `.env`)
   - Prompts for phone notification service name (`notify.mobile_app_*`)
   - Adds Wyoming whisper (STT) and piper (TTS) via REST API
   - Creates voice pipeline with Russian language via WebSocket API
   - Configures accept notifications via HTTP Request (no HA credential needed)
5. Say "Окей, Ассистент" to create tasks by voice. Results read back via TTS

**Configurable `.env` variables:**
- `HA_API_TOKEN` — API token (prompted on first run)
- `HA_NOTIFY_SERVICE` — full notification service name (e.g. `notify.mobile_app_infinix_x6731b`)
- `HA_PIPELINE_LANGUAGE` — voice assistant language (default `ru`)
- `HA_HOST` — HA host from n8n's perspective (default `host.docker.internal`)

## Project files

```
├── docker-compose.yml
├── .env.example
├── scripts/
│   ├── setup-stack.sh
│   ├── bootstrap-telegram-integration.sh
│   ├── setup-wyoming.py
│   ├── verify-stack.sh
│   └── cleanup-executions.sh
├── opencode/
│   ├── Dockerfile
│   └── bin/ (entrypoint, bootstrap-*.sh, install-github-tool.sh)
├── n8n/bootstrap/
│   ├── opencode-endpoints.json
│   └── workflows/templates/
├── ha_config/
│   ├── configuration.yaml
│   ├── automations.yaml
│   └── scripts.yaml
└── workers/
    └── config.json.default
```

## Getting help

- **Installation issues:** run `bash ./scripts/verify-stack.sh` — checks compose, n8n, workers
- **Telegram not working:** ensure `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_IDS` and `N8N_API_KEY` are set in `.env`, then `bash ./scripts/bootstrap-telegram-integration.sh`
- **Worker not responding:** `docker compose ps` — all services should be healthy; check logs: `docker compose logs opencode-worker-1 --tail 200`
- **Bugs and suggestions:** [GitHub Issues](https://github.com/RobertGard/home-dev-assistant/issues)

## Contributing

Pull requests welcome. Core principles:

- No hardcoded values in bash — all defaults from `config.json.default`
- `.env` — worker identity (Docker env vars), `config.json` — repo/tooling config (mounted into container)
- `docker compose down -v` must not require manual config restoration
- All scripts must pass `bash -n` (syntax check)
- `workers/config.json.default` is the single source of truth for tooling — no per-worker files in git
