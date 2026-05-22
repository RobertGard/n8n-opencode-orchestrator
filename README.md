# OpenCode + n8n

Self-hosted стек для автоматизации инженерных задач: n8n оркестрирует, OpenCode worker-ы исполняют, Telegram — интерфейс.

## Что делает

- Принимает задачи через Telegram-бота или напрямую через n8n
- Распределяет задачи по OpenCode worker-ам (любое количество)
- Worker-ы клонируют репозитории, ставят зависимости, выполняют задачи, поднимают Docker-инфраструктуру
- Поддерживает уточнения: если OpenCode нужен ввод — n8n запрашивает через Telegram и возвращает ответ
- Авто-генератор задач на базе AI Agent анализирует историю и предлагает следующие шаги

## Быстрый старт

```bash
bash ./scripts/setup-stack.sh
```

Скрипт проведёт через настройку: создаст `.env`, сконфигурирует worker-ов, запишет `config.json`, поднимет контейнеры, настроит Telegram (если указан токен), проверит стек.

### Переустановка (сброс до чистого состояния)

```bash
docker compose down -v --rmi all --remove-orphans
docker builder prune -af
bash ./scripts/setup-stack.sh
```

После `down -v` база n8n удалена — скрипт сам определит, что старый `N8N_API_KEY` недействителен, и запросит новый в интерактивном режиме.

## Требования

- Docker Engine + Docker Compose
- Telegram bot token (для Telegram-режима)
- Публичный домен, порты 80/443 и DNS (для HTTPS)

## Архитектура

### Сервисы (docker compose)

| Сервис | Назначение |
|--------|-----------|
| `postgres` | База n8n |
| `redis` | Очередь задач n8n (queue mode) |
| `n8n` | Оркестратор + редактор workflow |
| `n8n-worker` | Исполнитель workflow (queue mode) |
| `opencode-worker-1` | Основной OpenCode worker |
| `caddy` | Reverse proxy + авто-HTTP/S (опционально, профиль `proxy`) |

Дополнительные worker-ы добавляются через `compose.overrides/opencode-<name>.yml`.

### Поток задачи

```
Telegram → n8n (ingress)  →  Data Table agent_tasks
                                ↓
                          n8n (dispatcher) → OpenCode worker → n8n (result) → Telegram
```

Worker может вернуть `needs_input` — тогда n8n запрашивает уточнение через Telegram и возвращает ответ worker-у.

### OpenCode worker

Каждый worker в Docker-образе содержит:

- `opencode`, `git`, `gh`, `jq`, `ripgrep`, `fd`, `bat`, `tree`
- `docker`, `docker compose`
- `node`, `pnpm`, `bun`, `turbo`, `typescript`, `tsx`
- `python3`, `uv`
- `eslint`, `prettier`, `biome`, `vitest`, `jest`, `vite`, `prisma`, `shellcheck`, `yamllint`

Worker при старте:
1. Инициализирует OpenCode server на порту 4096
2. Читает `config.json` → клонирует репозитории, ставит зависимости
3. Читает `tooling` → устанавливает npm-пакеты, uv-инструменты, MCP-сервера, post-install команды
4. Поднимает Docker-инфраструктуру проекта (если включено)

## Конфигурация worker-а

### config.json

Файл создаётся скриптом `setup-stack.sh`. Содержит список репозиториев и опциональный блок `tooling`.

```json
{
  "repos": [
    {
      "slug": "my-project",
      "url": "https://github.com/user/my-project.git",
      "ref": "main",
      "path": "my-project",
      "package_manager": "auto",
      "turbo_smoke": false,
      "turbo_tasks": ["build", "test"],
      "auto_start_docker": true
    }
  ],
  "tooling": { ... }
}
```

#### Поля repo

| Поле | Значение по умолчанию | Назначение |
|------|----------------------|------------|
| `slug` | — | Идентификатор проекта |
| `url` | — | Git URL репозитория |
| `ref` | `main` | Ветка |
| `path` | slug | Папка внутри `/workspace` |
| `package_manager` | `auto` | `auto`/`pnpm`/`npm`/`npm-ci`/`bun` — чем ставить зависимости |
| `turbo_smoke` | `false` | Запускать ли `turbo run` после clone |
| `turbo_tasks` | `["build","test"]` | Какие задачи гонять (только при `turbo_smoke: true`) |
| `auto_start_docker` | `true` | Поднимать ли `docker compose up -d` в папке проекта |

Зависимости проекта (`pnpm install`/`npm install`/`bun install`) ставятся всегда — без флажка. Если в репо нет файла пакетного менеджера — команда ничего не делает.

### tooling (опционально)

Блок `tooling` в `config.json` управляет установкой глобальных пакетов и MCP-серверов. Берётся из шаблона:

```
workers/
├── config.json.default          ← глобальный дефолтный шаблон для всех worker-ов
├── worker-1/
│   ├── config.json.template     ← переопределяет глобальный для worker-1
│   └── config.json              ← рабочий конфиг (создаётся setup'ом)
└── worker-2/
    ├── config.json.template     ← переопределяет глобальный для worker-2
    └── config.json
```

Приоритет: `worker-N/config.json.template` → `workers/config.json.default`.

Структура tooling:

```json
"tooling": {
  "npm": [
    { "package": "get-shit-done-cc@latest", "args": "--opencode --global" },
    { "package": "@modelcontextprotocol/server-filesystem", "mcp": { "name": "filesystem", "args": ["/workspace"] } },
    { "package": "@modelcontextprotocol/server-git", "mcp": { "name": "git", "args": ["/workspace"] } },
    { "package": "@upstash/context7-mcp", "mcp": { "name": "context7", "type": "remote", "url": "https://mcp.context7.com/mcp" } }
  ],
  "uv": [
    { "package": "serena-agent@latest", "python": "3.13", "mcp": { "name": "serena", "command": ["serena", "start-mcp-server", "--context", "ide", "--project-from-cwd"], "enabled": true } }
  ],
  "post_install": [
    "serena init",
    "playwright install chromium"
  ]
}
```

| Секция | Что делает |
|--------|-----------|
| `npm` | `npm install -g`. Если есть `mcp` — регистрирует как MCP-сервер в OpenCode |
| `uv` | `uv tool install`. Аналогично с `mcp` |
| `post_install` | Команды после установки всех пакетов |

### config.json после переустановки

`config.json` лежит на bind-mount (`./workers/worker-N`) и не удаляется при `docker compose down -v`. При переустановке:

- **config.json существует и `enabled` не `false`** → не трогается
- **config.json отсутствует или `enabled: false`** → скрипт требует заново ввести slug/url репозитория

## n8n: workflow и данные

### Workflow

После bootstrap в n8n импортируются и активируются:

| Workflow | Файл шаблона | Роль |
|----------|-------------|------|
| Постановка задач через Telegram | `telegram-task-ingress.template.json` | Приём команд от бота |
| Диспетчер задач Telegram | `telegram-task-dispatcher.template.json` | Распределение по worker-ам |
| Менеджер сессий | `session-manager.template.json` | Управление сессиями OpenCode |
| Запуск задачи | `task-launcher.template.json` | Отправка задачи worker-у |
| Обработка интеракций | `pending-interaction.template.json` | Обработка `needs_input` |
| Завершение задачи | `task-finalizer.template.json` | Финализация результатов |
| Авто-генератор задач | `auto-task-generator.template.json` | AI Agent — предлагает следующие задачи |

### Data Tables

| Таблица | Назначение |
|---------|-----------|
| `agent_tasks` | Очередь задач: task_key, worker_alias, status, session_id, prompt, result_text |
| `chat_settings` | Настройки чатов: chat_id, auto_mode |

Статусы задач: `queued` → `running` → `done` / `failed` / `needs_input`.

### Credentials

| Credential | Тип | Создаётся автоматически |
|-----------|-----|------------------------|
| Telegram Bot | `telegramApi` | Да (если задан `TELEGRAM_BOT_TOKEN`) |
| DeepSeek API | `deepSeekApi` | Да (если задан `DEEPSEEK_API_KEY`) |

## .env — переменные окружения

Создаётся из `.env.example`. Ключевые группы:

**n8n:** `N8N_HOST`, `N8N_PROTOCOL`, `N8N_PORT`, `N8N_ENCRYPTION_KEY`, `N8N_BASIC_AUTH_*`, `N8N_API_KEY`

**База:** `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD`

**Worker N:** `OPENCODE_WORKER_N_NAME`, `_ALIAS`, `_PORT`, `_PASSWORD`, `_BASE_URL`, `_HEALTH_URL`

**API ключи:** `OPENAI_API_KEY`, `DEEPSEEK_API_KEY`, `ANTHROPIC_API_KEY`, `OPENROUTER_API_KEY`, `GITHUB_TOKEN`, `NPM_TOKEN`

**Telegram:** `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`

**OpenCode:** `OPENCODE_AGENT`, `OPENCODE_MODEL`, `OPENCODE_PROVIDER_TIMEOUT_MS`

## Ручной запуск

```bash
# Базовый (без внешнего доступа)
docker compose up -d --build

# С HTTPS через Caddy
docker compose --profile proxy up -d --build

# С дополнительными worker-ами
docker compose -f docker-compose.yml -f compose.overrides/opencode-worker-2.yml up -d --build
```

## Проверка стека

```bash
bash ./scripts/verify-stack.sh
```

Проверяет: compose-сервисы, n8n, routing-файл, worker-ы, Telegram-credential и workflow (если Telegram включён).

## Telegram: первый запуск

1. `bash ./scripts/setup-stack.sh` — укажи `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`
2. Открой n8n (`http://<сервер>:5678` или `https://<домен>`)
3. Settings → n8n API → создай API key
4. Добавь в `.env`: `N8N_API_KEY=<ключ>`
5. `bash ./scripts/bootstrap-telegram-integration.sh`

Скрипт сам определит протухший ключ после `docker compose down -v` и запросит новый.

## Основные файлы

```
├── docker-compose.yml                  # основной compose-файл
├── compose.overrides/                  # override-файлы для worker-ов 2+
├── .env.example                        # образец переменных окружения
├── infra/Caddyfile                     # конфиг reverse proxy
├── scripts/
│   ├── setup-stack.sh                  # установка и переустановка
│   ├── bootstrap-telegram-integration.sh # настройка Telegram
│   ├── verify-stack.sh                 # проверка стека
│   ├── cleanup-executions.sh           # очистка старых execution
│   └── lib/load-env.sh                 # загрузка .env
├── opencode/
│   ├── Dockerfile                      # образ OpenCode worker
│   └── bin/
│       ├── entrypoint.sh               # точка входа контейнера
│       ├── bootstrap-opencode.sh       # инициализация OpenCode + tooling
│       ├── bootstrap-repos.sh          # клонирование репозиториев
│       └── add-opencode-worker.sh      # создание дополнительного worker-а
├── n8n/bootstrap/
│   ├── opencode-routing.json           # routing worker-ов (генерируется)
│   └── workflows/templates/            # шаблоны workflow
└── workers/
    ├── config.json.default             # дефолтный tooling-шаблон
    ├── worker-1/
    │   ├── config.json.template        # переопределение tooling для worker-1
    │   └── config.json                 # рабочий конфиг (генерируется)
    └── worker-2/                       # аналогично для worker-2+
```

## Очистка execution

Каждый час (cron) удаляются execution старше 1 часа:

```bash
bash ./scripts/cleanup-executions.sh
```

Настраивается автоматически при `setup-stack.sh`. Требует `N8N_API_KEY` в `.env`.
