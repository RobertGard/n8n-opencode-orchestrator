# OpenCode + n8n

Self-hosted стек: n8n оркестрирует, OpenCode worker-ы исполняют, Telegram — интерфейс.

## Быстрый старт

```bash
bash ./scripts/setup-stack.sh
```

Скрипт задаст вопросы, создаст `.env` и `config.json`, поднимет контейнеры, настроит Telegram.

### Переустановка

```bash
docker compose down -v --rmi all --remove-orphans
docker builder prune -af
bash ./scripts/setup-stack.sh
```

## Команды Telegram-бота

Бот принимает команды через `/`. Флаги — через `--флаг="значение"`.

### `/task` — постановка и управление задачами

| Команда | Что делает |
|---|---|
| `/task --prompt="описание"` | Поставить новую задачу |
| `/task --answer="ответ"` | Ответить на вопрос OpenCode (авто-выбор pending-задачи) |
| `/task --task_key="xxx" --answer="ответ"` | Ответить на конкретную pending-задачу |
| `/task --parent_task_key="xxx" --parent_match_text="текст"` | Follow-up с проверкой вхождения |
| `/task --auto_mode="true"` | Включить авто-режим |
| `/task --auto_mode="false"` | Выключить авто-режим |

### `/abort` — прерывание задачи

| Команда | Что делает |
|---|---|
| `/abort --task_key="xxx"` | Прервать конкретную задачу |
| `/abort` | Авто-выбор единственной работающей задачи |

### Дополнительные флаги

| Флаг | Описание |
|---|---|
| `--worker="alias"` | Назначить задачу на конкретный worker |
| `--new_session` / `--fresh_session` | Принудительно создать новую сессию OpenCode |

### Ответы на вопросы OpenCode

OpenCode задаёт вопрос → бот присылает пронумерованные варианты.

- **Один вопрос** — номер или текст варианта
- **Несколько вопросов** — через `||`: `1 || Prisma`
- **Множественный выбор** — через `&&`: `1 && 3`
- **Отклонить** — `/reject` или `/task --answer="/reject"`

### Авто-режим

`/task --auto_mode="true"` — после каждой завершённой задачи бот предлагает следующую: GSD-цикл, проверку качества, тесты, документацию. Авто-задачи (префикс `auto-`) наследуют worker от задачи-триггера.

## Архитектура

```
Telegram → n8n ingress → Data Table → n8n dispatcher → OpenCode worker → результат в Telegram
```

**Сервисы:** `postgres`, `redis`, `n8n`, `n8n-worker`, `opencode-worker-1`, `caddy` (опционально)

**Workflow в n8n (7):** ingress, dispatcher, session-manager, task-launcher, pending-interaction, task-finalizer, auto-task-generator

## Конфигурация worker-а

Создаётся setup-скриптом в `workers/<name>/config.json`:

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

**Поля repo:** `slug`, `url`, `ref`, `path`, `package_manager` (по умолчанию `auto`), `turbo_smoke` (`false`), `turbo_tasks` (`["build","test"]`), `auto_start_docker` (`true`).

**tooling** (опционально) — глобальные пакеты и MCP-сервера. Структура: `npm` (npm install -g), `uv` (uv tool install), `post_install` (команды после). Пример в `workers/config.json.default`.

## Переменные окружения (.env)

Создаётся из `.env.example`. Основные разделы:

| Группа | Переменные |
|--------|-----------|
| n8n | `N8N_HOST`, `N8N_PROTOCOL`, `N8N_PORT`, `N8N_ENCRYPTION_KEY`, `N8N_BASIC_AUTH_*`, `N8N_API_KEY` |
| База | `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD` |
| Worker N | `OPENCODE_WORKER_N_NAME`, `_ALIAS`, `_PORT`, `_PASSWORD`, `_BASE_URL`, `_HEALTH_URL` |
| API ключи | `OPENAI_API_KEY`, `DEEPSEEK_API_KEY`, `ANTHROPIC_API_KEY`, `GITHUB_TOKEN` |
| Telegram | `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID` |
| OpenCode | `OPENCODE_AGENT`, `OPENCODE_MODEL`, `OPENCODE_PROVIDER_TIMEOUT_MS` |

## Операции

```bash
bash ./scripts/verify-stack.sh                 # Проверка стека
docker compose --profile proxy up -d --build   # Запуск с HTTPS
bash ./scripts/cleanup-executions.sh           # Очистка старых execution
```

## Где получить помощь

- **Проблемы с установкой:** `bash ./scripts/verify-stack.sh`
- **Telegram не работает:** проверь `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`, `N8N_API_KEY` в `.env`, затем `bash ./scripts/bootstrap-telegram-integration.sh`
- **Worker не отвечает:** `docker compose ps` — все сервисы должны быть healthy
- **Баги и предложения:** [GitHub Issues](https://github.com/RobertGard/n8n-opencode-orchestrator/issues)
