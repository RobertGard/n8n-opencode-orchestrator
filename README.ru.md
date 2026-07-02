# OpenCode + n8n

Self-hosted AI-ассистент для разработки: ставите задачу в Telegram, n8n диспетчеризует её на OpenCode worker-ы, результат приходит обратно в чат.

> **English version:** [README.md](./README.md)

**Ключевые возможности:**

- **Мульти-Worker** — любое количество worker-ов, каждый под свой проект и со своим набором MCP-инструментов
- **Сессии с контекстом** — worker помнит историю диалога, можно уточнять и дополнять задачи в рамках одной сессии
- **Интерактивный OpenCode** — worker может задать уточняющий вопрос прямо в чат, вы отвечаете, он продолжает
- **Авто-режим** — после завершения задачи бот сам анализирует результат и предлагает следующую: GSD-цикл, проверку качества, тесты, документацию
- **Цепочки задач** — задача может ждать завершения родительской и выполниться только при совпадении с указанным текстом в результате (тесты прошли → деплой)
- **Верификация приёмки** — передайте `--verify="критерии"` с задачей; после выполнения read-only verifier-агент проверит здоровье кода, логи приложения, консоль браузера (через Playwright), ответы API и каждый критерий по отдельности. При FAILED авто-создаётся задача-фикс
- **Команды на естественном языке** — пишите запросы обычным текстом; AI-транслятор преобразует их в структурированные команды с правильными флагами
- **Полностью self-hosted** — никаких облачных сервисов, все данные под вашим контролем
- **Стек из коробки** — PostgreSQL, Redis, n8n, Caddy (HTTPS) — один `bash setup-stack.sh` и всё готово

## Требования

- Docker Engine + Docker Compose
- Telegram bot token (для Telegram-режима)
- Публичный домен, порты 80/443 (для HTTPS)

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
| `--verify="критерии"` | Критерии приёмки — после выполнения задачи read-only verifier-агент проверит: здоровье кода (lint, typecheck, тесты), логи приложения (docker logs для каждого контейнера), консоль браузера (Playwright), ответы API и каждый критерий по отдельности. При провале автоматически создаётся задача исправления |

### Ответы на вопросы OpenCode

OpenCode задаёт вопрос → бот присылает пронумерованные варианты.

- **Один вопрос** — номер или текст варианта
- **Несколько вопросов** — через `||`: `1 || Prisma`
- **Множественный выбор** — через `&&`: `1 && 3`
- **Отклонить** — `/reject` или `/task --answer="/reject"`

### Авто-режим

`/task --auto_mode="true"` — после каждой завершённой задачи бот предлагает следующую: GSD-цикл, проверку качества, тесты, документацию. Авто-задачи (префикс `auto-`) наследуют worker от задачи-триггера.

### Команды на естественном языке

Необязательно писать структурированные команды. Пишите обычным текстом:

| Вход | Результат трансляции |
|---|---|
| `разверни проект` | `/task --prompt="разверни проект"` |
| `выполни правки во втором воркере` | `/task --prompt="выполни правки" --worker="worker-2"` |
| `ответь 2 в задаче task-abc` | `/task --task_key="task-abc" --answer="2"` |
| `если в задаче task-abc есть "готово" то выполни очистку` | `/task --parent_task_key="task-abc" --parent_match_text="готово" --prompt="выполни очистку"` |
| `включи автомод` | `/task --auto_mode="true"` |
| `отмени задачу task-xyz` | `/abort --task_key="task-xyz"` |
| `сделай рефакторинг. проверь что линтер проходит и тесты зелёные` | `/task --prompt="сделай рефакторинг" --verify="линтер проходит и тесты зелёные"` |
| `/task --prompt="уже команда"` | `/task --prompt="уже команда"` (пропускается без изменений) |

Транслятор — AI Agent (DeepSeek), работающий перед парсером команд. Он сохраняет исходный смысл, не выдумывает флаги и пропускает существующие команды без изменений.

### Пайплайн верификации приёмки

При использовании `--verify="критерии"`:

1. OpenCode выполняет основную задачу
2. Диспетчер запускает **отдельную сессию OpenCode** с **read-only verifier-агентом** (`edit: deny, bash: allow`)
3. Верификатор выполняет 4 обязательных чекпоинта:
   - **Здоровье кода и сборки**: lint, typecheck, тесты, `git diff`
   - **Логи приложения**: `docker logs --tail 100` для каждого контейнера, файлы логов
   - **Поведение в рантайме**: curl-проверки API, взаимодействие через Playwright (логи консоли, сетевые ошибки, содержимое страниц)
   - **Проверка по критериям**: каждый критерий приёмки сопоставляется с доказательствами
4. Каждый чекпоинт **требует реальный вывод команд как доказательство** — агент не может пропустить или сфабриковать
5. **AI-судья (DeepSeek)** оценивает отчёт верификации и возвращает вердикт PASSED/FAILED
6. При FAILED → автоматически создаётся задача исправления с теми же `--verify` критериями

## Архитектура

```
Telegram → n8n ingress → Data Table → n8n dispatcher → OpenCode worker → результат в Telegram
```

**Сервисы:** `postgres`, `redis`, `n8n`, `n8n-worker`, `opencode-worker-1`, `caddy` (опционально)

**Workflow в n8n (8):** ingress, dispatcher, session-manager, task-launcher, pending-interaction, task-finalizer, auto-task-generator, acceptance-verifier

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

**Шаблоны:**

```
workers/
├── config.json.default          ← дефолтный tooling для всех worker-ов
├── worker-1/
│   ├── config.json.template     ← переопределяет default для worker-1
│   └── config.json              ← рабочий конфиг
└── worker-2/
    └── ...
```

Приоритет: `worker-N/config.json.template` → `workers/config.json.default`.

**Поведение при переустановке:** `config.json` на bind-mount переживает `docker compose down -v`. Если отсутствует или disabled — скрипт требует новый slug/url.

## Переменные окружения (.env)

Создаётся из `.env.example`. Основные разделы:

| Группа | Переменные |
|---|---|
| n8n | `N8N_HOST`, `N8N_PROTOCOL`, `N8N_PORT`, `N8N_ENCRYPTION_KEY`, `N8N_BASIC_AUTH_*`, `N8N_API_KEY` |
| База | `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD` |
| Worker N | `OPENCODE_WORKER_N_NAME`, `_ALIAS`, `_PORT`, `_PASSWORD`, `_BASE_URL`, `_HEALTH_URL` |
| API ключи | `OPENAI_API_KEY`, `DEEPSEEK_API_KEY`, `ANTHROPIC_API_KEY`, `OPENROUTER_API_KEY`, `GITHUB_TOKEN` |
| Telegram | `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID` |
| OpenCode | `OPENCODE_AGENT`, `OPENCODE_MODEL`, `OPENCODE_PROVIDER_TIMEOUT_MS` |

## Операции

```bash
# Проверка стека
bash ./scripts/verify-stack.sh

# Запуск с HTTPS
docker compose --profile proxy up -d --build

# Дополнительные worker-ы
docker compose -f docker-compose.yml -f compose.overrides/opencode-worker-2.yml up -d --build

# Очистка execution (автоматически через cron)
bash ./scripts/cleanup-executions.sh
```

## Telegram: первый запуск

1. `bash ./scripts/setup-stack.sh` → укажи `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`
2. Открой n8n → Settings → n8n API → создай API key
3. Добавь в `.env`: `N8N_API_KEY=<ключ>`
4. `bash ./scripts/bootstrap-telegram-integration.sh`

После `docker compose down -v` скрипт сам определит протухший ключ и запросит новый.

## Файлы проекта

```
├── docker-compose.yml
├── .env.example
├── scripts/
│   ├── setup-stack.sh
│   ├── bootstrap-telegram-integration.sh
│   ├── verify-stack.sh
│   └── cleanup-executions.sh
├── opencode/
│   ├── Dockerfile
│   └── bin/ (entrypoint, bootstrap-*.sh)
├── n8n/bootstrap/
│   ├── opencode-routing.json
│   └── workflows/templates/
└── workers/
    ├── config.json.default
    ├── worker-1/
    └── worker-2/
```

## Где получить помощь

- **Проблемы с установкой:** запусти `bash ./scripts/verify-stack.sh` — проверит compose, n8n, worker-ы
- **Telegram не работает:** убедись, что `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID` и `N8N_API_KEY` заданы в `.env`, затем `bash ./scripts/bootstrap-telegram-integration.sh`
- **Worker не отвечает:** `docker compose ps` — все сервисы должны быть healthy
- **Баги и предложения:** [GitHub Issues](https://github.com/RobertGard/n8n-opencode-orchestrator/issues)

## Контрибьютинг

Присылайте PR. Основные принципы:

- Никаких захардкоженных значений в bash-коде — все дефолты из `config.json.template` или `config.json.default`
- `.env` — identity worker-ов (Docker env vars), `config.json` — repo/tooling конфиг (монтируется в контейнер)
- `docker compose down -v` не должен требовать ручного восстановления конфигурации
- Все скрипты должны проходить `bash -n` (синтаксическая проверка)
